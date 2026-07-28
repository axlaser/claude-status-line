//! Two of the areas platform-conditional code is confined to: file-ownership
//! checks and process-entry stream handling. Notification delivery is the third
//! and lives in the `notify` submodule.
//!
//! Keep new `#[cfg]` code here rather than scattering it —
//! `platform_conditional_code_stays_in_its_areas` asserts the file list.

use std::path::Path;

pub mod notify;

#[cfg(unix)]
mod imp {
    use std::os::unix::fs::MetadataExt;
    use std::path::Path;

    /// Layer 1 of silent degradation. Nothing below the panic hook can be trusted
    /// to stay quiet
    /// — a stack overflow or allocation failure writes straight to fd 2 from
    /// the runtime — so the descriptor is redirected before anything runs.
    pub fn redirect_stderr_to_null() {
        unsafe {
            let path = b"/dev/null\0";
            let fd = libc::open(path.as_ptr() as *const libc::c_char, libc::O_WRONLY);
            if fd >= 0 {
                libc::dup2(fd, libc::STDERR_FILENO);
                if fd != libc::STDERR_FILENO {
                    libc::close(fd);
                }
            }
        }
    }

    pub fn current_owner() -> Option<u64> {
        Some(unsafe { libc::geteuid() } as u64)
    }

    /// Uses `symlink_metadata` so a symlink reports its own ownership rather
    /// than its target's.
    pub fn trusted_owners() -> Vec<u64> {
        current_owner().into_iter().collect()
    }

    pub fn file_owner(path: &Path) -> Option<u64> {
        std::fs::symlink_metadata(path).ok().map(|m| m.uid() as u64)
    }
}

#[cfg(windows)]
mod imp {
    use std::os::windows::ffi::OsStrExt;
    use std::path::Path;

    use windows_sys::Win32::Foundation::{CloseHandle, LocalFree, ERROR_SUCCESS, HANDLE};
    use windows_sys::Win32::Security::Authorization::{GetNamedSecurityInfoW, SE_FILE_OBJECT};
    use windows_sys::Win32::Security::{
        CreateWellKnownSid, GetLengthSid, GetTokenInformation, TokenUser,
        WinBuiltinAdministratorsSid, OWNER_SECURITY_INFORMATION, PSECURITY_DESCRIPTOR, PSID,
        TOKEN_QUERY, TOKEN_USER,
    };
    use windows_sys::Win32::Storage::FileSystem::{
        CreateFileW, FILE_ATTRIBUTE_NORMAL, FILE_GENERIC_WRITE, FILE_SHARE_READ, FILE_SHARE_WRITE,
        OPEN_EXISTING,
    };
    use windows_sys::Win32::System::Console::{SetStdHandle, STD_ERROR_HANDLE};
    use windows_sys::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};

    fn wide(s: &Path) -> Vec<u16> {
        s.as_os_str()
            .encode_wide()
            .chain(std::iter::once(0))
            .collect()
    }

    /// Layer 1, Windows form: swap the process's standard error handle for
    /// one on `NUL`.
    pub fn redirect_stderr_to_null() {
        unsafe {
            let name: Vec<u16> = "NUL\0".encode_utf16().collect();
            let h = CreateFileW(
                name.as_ptr(),
                FILE_GENERIC_WRITE,
                FILE_SHARE_READ | FILE_SHARE_WRITE,
                std::ptr::null(),
                OPEN_EXISTING,
                FILE_ATTRIBUTE_NORMAL,
                std::ptr::null_mut(),
            );
            if !h.is_null() && h as isize != -1 {
                SetStdHandle(STD_ERROR_HANDLE, h);
            }
        }
    }

    /// Hashes a SID's bytes into a comparable id. Only equality matters here,
    /// so a stable digest is enough and avoids carrying raw pointers around.
    unsafe fn sid_id(sid: PSID) -> Option<u64> {
        if sid.is_null() {
            return None;
        }
        let len = GetLengthSid(sid) as usize;
        if len == 0 {
            return None;
        }
        let bytes = std::slice::from_raw_parts(sid as *const u8, len);
        // FNV-1a: stable across runs, which is all an equality check needs.
        let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
        for b in bytes {
            hash ^= *b as u64;
            hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
        }
        Some(hash)
    }

    pub fn current_owner() -> Option<u64> {
        unsafe {
            let mut token: HANDLE = std::ptr::null_mut();
            if OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) == 0 {
                return None;
            }
            let mut needed: u32 = 0;
            GetTokenInformation(token, TokenUser, std::ptr::null_mut(), 0, &mut needed);
            if needed == 0 {
                CloseHandle(token);
                return None;
            }
            let mut buf = vec![0u8; needed as usize];
            let ok = GetTokenInformation(
                token,
                TokenUser,
                buf.as_mut_ptr() as *mut _,
                needed,
                &mut needed,
            );
            CloseHandle(token);
            if ok == 0 {
                return None;
            }
            let tu = &*(buf.as_ptr() as *const TOKEN_USER);
            sid_id(tu.User.Sid)
        }
    }

    /// The Administrators group, which owns everything an elevated process
    /// creates.
    ///
    /// A standard user cannot produce a file owned by this group, so accepting
    /// it does not widen the set of principals the guard defends against — an
    /// administrator already owns the binary, `settings.json`, and the ability
    /// to take ownership of anything else. `install.ps1` has accepted admin
    /// ownership of the install directory since it was written; this is the
    /// runtime catching up to it.
    fn administrators() -> Option<u64> {
        unsafe {
            let mut size: u32 = 0;
            CreateWellKnownSid(
                WinBuiltinAdministratorsSid,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                &mut size,
            );
            if size == 0 {
                return None;
            }
            let mut buf = vec![0u8; size as usize];
            if CreateWellKnownSid(
                WinBuiltinAdministratorsSid,
                std::ptr::null_mut(),
                buf.as_mut_ptr() as PSID,
                &mut size,
            ) == 0
            {
                return None;
            }
            sid_id(buf.as_ptr() as PSID)
        }
    }

    pub fn trusted_owners() -> Vec<u64> {
        let mut out = Vec::with_capacity(2);
        out.extend(current_owner());
        out.extend(administrators());
        out
    }

    /// Returns `None` when the owner cannot be determined. That is not a
    /// failure signal — see `state::owner_check_passes` for why it must
    /// degrade to the symlink guard rather than failing closed.
    pub fn file_owner(path: &Path) -> Option<u64> {
        unsafe {
            let w = wide(path);
            let mut owner: PSID = std::ptr::null_mut();
            let mut sd: PSECURITY_DESCRIPTOR = std::ptr::null_mut();
            let rc = GetNamedSecurityInfoW(
                w.as_ptr(),
                SE_FILE_OBJECT,
                OWNER_SECURITY_INFORMATION,
                &mut owner,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                &mut sd,
            );
            if rc != ERROR_SUCCESS {
                return None;
            }
            let id = sid_id(owner);
            if !sd.is_null() {
                LocalFree(sd as *mut _);
            }
            id
        }
    }
}

pub use imp::redirect_stderr_to_null;

/// The current user's comparable owner id, or `None` when it cannot be read.
pub fn current_owner() -> Option<u64> {
    imp::current_owner()
}

/// Every owner id a state file may legitimately carry: this process's user,
/// plus the Administrators group on Windows.
pub fn trusted_owners() -> Vec<u64> {
    imp::trusted_owners()
}

/// The owner id of `path` itself (not its symlink target), or `None` when it
/// cannot be determined.
pub fn file_owner(path: &Path) -> Option<u64> {
    imp::file_owner(path)
}
