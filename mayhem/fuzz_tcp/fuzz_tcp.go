// Package fuzz_tcp drives layers.TCP.SerializeTo with options built from fuzz bytes.
//
// Input: [flags][padlen][records...]; flags bit0 = FixLengths. Each record is
// [kind][optionLength][datalen][data...]; a truncated record ends the list.
package fuzz_tcp

import (
	"github.com/google/gopacket"
	"github.com/google/gopacket/layers"
)

func FuzzTCPSerialize(data []byte) int {
	if len(data) < 2 {
		return -1
	}
	flags, padLen := data[0], int(data[1]%8)
	data = data[2:]

	tcp := &layers.TCP{SrcPort: 1234, DstPort: 80, SYN: true, Padding: make([]byte, padLen)}
	for len(data) >= 3 {
		kind, optLen, dlen := data[0], data[1], int(data[2])
		data = data[3:]
		if dlen > len(data) {
			break
		}
		tcp.Options = append(tcp.Options, layers.TCPOption{
			OptionType:   layers.TCPOptionKind(kind),
			OptionLength: optLen,
			OptionData:   data[:dlen],
		})
		data = data[dlen:]
	}

	buf := gopacket.NewSerializeBuffer()
	opts := gopacket.SerializeOptions{FixLengths: flags&1 != 0}
	if err := gopacket.SerializeLayers(buf, opts, tcp); err != nil {
		return 0
	}
	if opts.FixLengths {
		gopacket.NewPacket(buf.Bytes(), layers.LayerTypeTCP, gopacket.Default).String()
	}
	return 1
}
