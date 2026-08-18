# Finding: unchecked RadioTap header length causes a slice-bounds panic

Found within the first 15s of a local `fuzz_layers` smoke run seeded from
`mayhem/fuzz_layers/testsuite/` (starting from `radiotap0.bin`, upstream's own
`layers/radiotap_test.go` fixture).

## Reproducer

`radiotap-length-oob-panic.bin` (11 bytes, minimized with
`-minimize_crash=1`):

```
00 40 ff ff 00 a1 ae 9d cb c6 4b
```

Replay directly against the harness:

```
/mayhem/fuzz_layers -runs=1 mayhem/fuzz_layers/known-findings/radiotap-length-oob-panic.bin
```

Per `layers/fuzz_layer.go`'s own input format, the first two bytes select the
starting `gopacket.LayerType` and the third byte packs the four
`DecodeOptions` bits. Byte 0-1 = `0x0040` = 64 = `LayerTypeRadioTap`. Byte 2 =
`0xff` sets all four bits, including `SkipDecodeRecovery` (bit `0x4`) — see
Impact below for why that bit matters.

## Crash

```
panic: runtime error: slice bounds out of range [4608:33]

github.com/google/gopacket/layers.(*RadioTap).DecodeFromBytes(...)
	layers/radiotap.go:868 +0x1aa5
```

## Cause

`RadioTap.DecodeFromBytes` (`layers/radiotap.go`) reads the header's `Length`
field straight off the wire with no bound check:

```go
m.Length = binary.LittleEndian.Uint16(data[2:4])   // radiotap.go:738 — attacker-controlled, unchecked
...
payload := data[m.Length:]                          // radiotap.go:868 — slices past len(data) if Length is too large
...
m.BaseLayer = BaseLayer{Contents: data[:m.Length], Payload: payload}  // radiotap.go:900 — same issue
```

Nothing between the two lines validates `m.Length <= len(data)`, so a crafted
RadioTap header whose length field exceeds the actual buffer size panics with
"slice bounds out of range" instead of returning a decode error.

## Impact

`gopacket`'s own decode path is normally panic-safe: `packet.recoverDecodeError`
(`packet.go:196-202`) wraps decoding in a `recover()` and turns any panic into a
`DecodeFailure` layer — **unless the caller has set
`DecodeOptions.SkipDecodeRecovery = true`**, which the package's own doc comment
describes as an explicit opt-in "skip[ping] over panic recovery during packet
decoding" for callers who want to avoid recover()'s overhead
(`packet.go:620-625`).

So, honestly stated: with `gopacket`'s DEFAULT decode options (what the large
majority of consumers use), this exact input does **not** crash a hosting
process — the panic is caught and surfaces as an `ErrorLayer()`, matching
upstream's documented behavior. The finding is nonetheless real: any consumer
that has opted into `SkipDecodeRecovery` (upstream's own docs suggest this for
high-throughput parsing) will crash the whole process on a single malformed
802.11 capture frame — a parser-inherent DoS, not a harness artifact. A
defensive library ideally should not be able to panic at all from attacker
input regardless of caller options; the one-line upstream fix is a bound check
before the two slices above:

```go
if int(m.Length) > len(data) {
    return errors.New("radiotap: header length exceeds packet data")
}
```

## Status

Not reported upstream (this is a savantenvs integration port, not an
upstream-facing bug report). Recorded here as an integration finding per the
port workflow; a defect ticket can be filed from this reproducer.
