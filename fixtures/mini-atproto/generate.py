#!/usr/bin/env python3
"""Generate fixtures/mini-atproto deterministically: repo.car + blobs/.

Stdlib only. Produces a CAR v1 file whose MST root holds six records in a
single node (no key-hash collisions at depth 0), plus one blob file named by
its CID string. All identities are synthetic.
"""
import base64
import hashlib
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
DID = "did:plc:testuser0000000000000"
OTHER = "did:plc:otheruser000000000000"


def varint(n):
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            break
    return bytes(out)


def cbor_uint(n):
    if n < 24:
        return bytes([n])
    if n < 256:
        return b"\x18" + bytes([n])
    if n < 65536:
        return b"\x19" + n.to_bytes(2, "big")
    if n < 2**32:
        return b"\x1a" + n.to_bytes(4, "big")
    return b"\x1b" + n.to_bytes(8, "big")


def cbor_bytes(b):
    hdr = cbor_uint(len(b))
    return bytes([hdr[0] | 0x40]) + hdr[1:] + b


def cbor_text(s):
    b = s.encode("utf-8")
    hdr = cbor_uint(len(b))
    return bytes([hdr[0] | 0x60]) + hdr[1:] + b


def cbor_array(items):
    hdr = cbor_uint(len(items))
    return bytes([hdr[0] | 0x80]) + hdr[1:] + b"".join(items)


def cbor_map(pairs):
    enc = [(cbor_text(k), v) for k, v in pairs]
    enc.sort(key=lambda kv: (len(kv[0]), kv[0]))
    hdr = cbor_uint(len(enc))
    return bytes([hdr[0] | 0xA0]) + hdr[1:] + b"".join(k + v for k, v in enc)


def cbor_null():
    return b"\xF6"


def cbor_link(cid):
    return b"\xD8\x2A" + cbor_bytes(b"\x00" + cid)


def cid_v1(codec, data):
    digest = hashlib.sha256(data).digest()
    return b"\x01" + varint(codec) + varint(0x12) + varint(0x20) + digest


def cid_str(cid):
    return "b" + base64.b32encode(cid).decode().lower().rstrip("=")


DAG_CBOR = 0x71
RAW = 0x55


def rec(pairs):
    return cbor_map(pairs)


def blob_ref(link_str, mime, size):
    return rec([
        ("$type", cbor_text("blob")),
        ("ref", rec([("$link", cbor_text(link_str))])),
        ("mimeType", cbor_text(mime)),
        ("size", cbor_uint(size)),
    ])


def strong_ref(uri, cid_string):
    return rec([("cid", cbor_text(cid_string)), ("uri", cbor_text(uri))])


def main():
    blobs_dir = os.path.join(HERE, "blobs")
    os.makedirs(blobs_dir, exist_ok=True)

    png = b"\x89PNG\r\n\x1a\n" + b"mini-atproto-placeholder"
    blob_cid = cid_v1(RAW, png)
    blob_str = cid_str(blob_cid)
    with open(os.path.join(blobs_dir, blob_str), "wb") as f:
        f.write(png)

    post1_text = "Hello small archive #testtag"
    tag_start = post1_text.index("#")
    post1 = rec([
        ("$type", cbor_text("app.bsky.feed.post")),
        ("createdAt", cbor_text("2024-02-01T12:00:00Z")),
        ("embed", rec([
            ("$type", cbor_text("app.bsky.embed.images")),
            ("images", cbor_array([rec([
                ("alt", cbor_text("tiny placeholder image")),
                ("image", blob_ref(blob_str, "image/png", len(png))),
            ])])),
        ])),
        ("facets", cbor_array([rec([
            ("$type", cbor_text("app.bsky.richtext.facet")),
            ("features", cbor_array([rec([
                ("$type", cbor_text("app.bsky.richtext.facet#tag")),
                ("tag", cbor_text("testtag")),
            ])])),
            ("index", rec([
                ("byteEnd", cbor_uint(tag_start + 8)),
                ("byteStart", cbor_uint(tag_start)),
            ])),
        ])])),
        ("langs", cbor_array([cbor_text("en")])),
        ("text", cbor_text(post1_text)),
    ])
    post1_cid = cid_v1(DAG_CBOR, post1)
    post1_uri = f"at://{DID}/app.bsky.feed.post/3kpost1"

    post2 = rec([
        ("$type", cbor_text("app.bsky.feed.post")),
        ("createdAt", cbor_text("2024-02-01T12:05:00Z")),
        ("langs", cbor_array([cbor_text("en")])),
        ("reply", rec([
            ("parent", strong_ref(post1_uri, cid_str(post1_cid))),
            ("root", strong_ref(post1_uri, cid_str(post1_cid))),
        ])),
        ("text", cbor_text("Self reply for the thread")),
    ])

    ext_uri = f"at://{OTHER}/app.bsky.feed.post/9xext1"
    post3 = rec([
        ("$type", cbor_text("app.bsky.feed.post")),
        ("createdAt", cbor_text("2024-02-01T12:10:00Z")),
        ("langs", cbor_array([cbor_text("en")])),
        ("reply", rec([
            ("parent", strong_ref(ext_uri, cid_str(cid_v1(DAG_CBOR, b"ext")))),
            ("root", strong_ref(ext_uri, cid_str(cid_v1(DAG_CBOR, b"ext")))),
        ])),
        ("text", cbor_text("Reply to another account")),
    ])

    doc = rec([
        ("$type", cbor_text("site.standard.document")),
        ("path", cbor_text("/hello")),
        ("publishedAt", cbor_text("2024-02-05T00:00:00Z")),
        ("site", cbor_text("https://example.com")),
        ("tags", cbor_array([cbor_text("doc"), cbor_text("standard")])),
        ("text", cbor_text("A standard.site document body.")),
        ("title", cbor_text("Hello Doc")),
    ])

    profile = rec([
        ("$type", cbor_text("app.bsky.actor.profile")),
        ("description", cbor_text("Synthetic profile for tests.")),
        ("displayName", cbor_text("Test User")),
    ])

    like = rec([
        ("$type", cbor_text("app.bsky.feed.like")),
        ("createdAt", cbor_text("2024-02-01T12:30:00Z")),
        ("subject", strong_ref(post1_uri, cid_str(post1_cid))),
    ])

    entries = [
        ("app.bsky.actor.profile/self", profile),
        ("app.bsky.feed.like/3klike1", like),
        ("app.bsky.feed.post/3kpost1", post1),
        ("app.bsky.feed.post/3kpost2", post2),
        ("app.bsky.feed.post/3kpost3", post3),
        ("site.standard.document/3kdoc1", doc),
    ]

    blocks = []  # (cid, dag-cbor bytes) in write order
    record_cids = {}
    for key, body in entries:
        c = cid_v1(DAG_CBOR, body)
        record_cids[key] = c
        blocks.append((c, body))

    # Single-node MST root: entries sorted by key bytes, p/k/prefix chain.
    e = []
    prev = b""
    for key, _body in sorted(entries, key=lambda kv: kv[0]):
        kb = key.encode()
        p = 0
        while p < len(prev) and p < len(kb) and prev[p] == kb[p]:
            p += 1
        e.append(rec([
            ("k", cbor_bytes(kb[p:])),
            ("p", cbor_uint(p)),
            ("t", cbor_null()),
            ("v", cbor_link(record_cids[key])),
        ]))
        prev = kb
    mst_root = rec([("e", cbor_array(e)), ("l", cbor_null())])
    mst_cid = cid_v1(DAG_CBOR, mst_root)
    blocks.append((mst_cid, mst_root))

    # CAR roots point at the commit object; its `data` link is the MST root.
    commit = rec([
        ("data", cbor_link(mst_cid)),
        ("did", cbor_text(DID)),
        ("prev", cbor_null()),
        ("rev", cbor_text("3kt2ze0ymf7er")),
        ("sig", cbor_bytes(b"\xde\xad\xbe\xef" * 16)),
        ("version", cbor_uint(3)),
    ])
    commit_cid = cid_v1(DAG_CBOR, commit)
    blocks.append((commit_cid, commit))

    header = cbor_map([
        ("roots", cbor_array([cbor_link(commit_cid)])),
        ("version", cbor_uint(1)),
    ])
    car = bytearray()
    car += varint(len(header)) + header
    for c, body in blocks:
        car += varint(len(c) + len(body)) + c + body
    with open(os.path.join(HERE, "repo.car"), "wb") as f:
        f.write(car)

    print(f"wrote repo.car ({len(car)} bytes), {len(blocks)} blocks, blob {blob_str}")


if __name__ == "__main__":
    main()
