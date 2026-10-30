// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// sample.goose - Example binary message packet framer and decoder.
namespace sample;

import std;

struct PacketHeader {
    magic:       u16,
    version:     u8,
    msg_type:    u8,
    payload_len: u32,
}

fn parse_header(buf: const u8[:]) -> PacketHeader, bool {
    if buf.len < 8 {
        return PacketHeader { magic: 0, version: 0, msg_type: 0, payload_len: 0 }, false;
    }

    let magic = ((buf[0] as u16) << 8) | buf[1];
    let version = buf[2];
    let msg_type = buf[3];
    let payload_len = ((buf[4] as u32) << 24)
        | ((buf[5] as u32) << 16)
        | ((buf[6] as u32) << 8)
        | buf[7];

    return PacketHeader {
        magic:       magic,
        version:     version,
        msg_type:    msg_type,
        payload_len: payload_len,
    }, true;
}

fn print_packet_summary(hdr: const PacketHeader&) {
    print("PACKET: magic=", hdr.magic, " ver=", hdr.version, " type=", hdr.msg_type, " len=", hdr.payload_len);
}
