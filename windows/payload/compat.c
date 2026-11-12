/* MinGW build of cryptlib for Mystic on Windows 7 32-bit (Shadowscope BBS).
   MinGW's versionhelpers.h has no out-of-line IsWindowsXPOrGreater; every
   system this DLL runs on (Windows 7 or later) is XP or greater. */
#include <windows.h>
BOOL IsWindowsXPOrGreater(void) { return TRUE; }
