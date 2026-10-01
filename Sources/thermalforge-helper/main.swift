//
//  main.swift
//  thermalforge-helper
//
//  Privileged helper embedded in ThermalForge.app and run as root by launchd
//  (SMAppService bundle daemon). Replaces the old `/usr/local/bin/thermalforge
//  daemon --owner-uid <uid>` CLI subcommand: the helper takes no arguments, and
//  the owner model is now root:admin 0660 on the socket (see DaemonServer.init).
//

import Darwin
import Foundation
import ThermalForgeCore

// R4: a client that closes its end mid-reply must surface as a write error, not
// kill this process with SIGPIPE. Ignore it before any socket work — the
// per-fd SO_NOSIGPIPE in DaemonClient/ConnectionServer is belt-and-braces, this
// is the process-wide backstop for every fd that doesn't set it.
signal(SIGPIPE, SIG_IGN)

// launchd loads us as a system LaunchDaemon (root). Running unprivileged is
// never useful — the SMC write path needs root, and the admin-only socket
// contract assumes a root-owned listener. Refuse loudly and exit nonzero so
// KeepAlive surfaces the misconfiguration in Console.app instead of quietly
// serving an unprivileged, unusable socket.
guard geteuid() == 0 else {
    FileHandle.standardError.write(Data(
        "thermalforge-helper: must run as root (launchd system daemon); euid is not 0.\n".utf8
    ))
    exit(1)
}

let fc = try FanControl()
let server = try DaemonServer(fanControl: fc)
server.run()
