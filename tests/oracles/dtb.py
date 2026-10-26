#!/usr/bin/env python3
# Independent encoder of the machine device tree in src/boot/dtb.bend: prints
# the two expected blobs of laws/dtb.bend as JSON ({"a": two_cpus, "b": minimal}).
# Check its output with: dtc -I dtb -O dts.
import struct, sys, json
def pad4(b): return b + b'\0'*((-len(b))%4)
def u32(*vs): return b''.join(struct.pack('>I', v) for v in vs)
def u64(v): return struct.pack('>Q', v)
def s(x): return x.encode()+b'\0'
def ss(*xs): return b''.join(s(x) for x in xs)
def build(root, cpuid=0):
    names=[]
    def walk(n):
        for (k,v) in n[1]:
            if k not in names: names.append(k)
        for c in n[2]: walk(c)
    walk(root)
    strings=b''.join(k.encode()+b'\0' for k in names)
    off={}; o=0
    for k in names: off[k]=o; o+=len(k)+1
    def ser(n):
        out=struct.pack('>I',1)+pad4(n[0].encode()+b'\0')
        for (k,v) in n[1]: out+=struct.pack('>III',3,len(v),off[k])+pad4(v)
        for c in n[2]: out+=ser(c)
        return out+struct.pack('>I',2)
    st=ser(root)+struct.pack('>I',9)
    off_struct=56; off_strings=off_struct+len(st); total=off_strings+len(strings)
    hdr=struct.pack('>10I',0xd00dfeed,total,off_struct,off_strings,40,17,16,cpuid,len(strings),len(st))
    return hdr+b'\0'*16+st+strings

def machine(ncpus, ram_size, bootargs, initrd, nvirtio, display=None):
    chosen=[("bootargs", s(bootargs)), ("stdout-path", s("/pl011@9000000"))]
    if initrd: chosen += [("linux,initrd-start", u64(initrd[0])), ("linux,initrd-end", u64(initrd[1]))]
    cpus=[("cpu@%x"%i, [("device_type", s("cpu")), ("compatible", s("arm,arm-v8")), ("reg", u32(i)), ("enable-method", s("psci"))], []) for i in range(ncpus)]
    virtio=[("virtio_mmio@%x"%(0x0a000000+i*0x200), [("compatible", s("virtio,mmio")), ("reg", u32(0, 0x0a000000+i*0x200, 0, 0x200)), ("interrupts", u32(0, 16+i, 1)), ("dma-coherent", b"")], []) for i in range(nvirtio)]
    root=("", [("compatible", s("linux,dummy-virt")), ("model", s("bend-vmm")), ("#address-cells", u32(2)), ("#size-cells", u32(2)), ("interrupt-parent", u32(1))], [
      ("chosen", chosen, []),
      ("memory@40000000", [("device_type", s("memory")), ("reg", u32(0, 0x40000000) + u64(ram_size))], []),
      ("cpus", [("#address-cells", u32(1)), ("#size-cells", u32(0))], cpus),
      ("psci", [("compatible", ss("arm,psci-1.0", "arm,psci-0.2")), ("method", s("hvc"))], []),
      ("timer", [("compatible", s("arm,armv8-timer")), ("interrupts", u32(1, 13, 4, 1, 14, 4, 1, 11, 4, 1, 10, 4)), ("always-on", b"")], []),
      ("intc@8000000", [("compatible", s("arm,gic-v3")), ("#interrupt-cells", u32(3)), ("interrupt-controller", b""), ("reg", u32(0, 0x08000000, 0, 0x10000, 0, 0x0c000000, 0, 0x2000000)), ("phandle", u32(1))], []),
      ("apb-pclk", [("compatible", s("fixed-clock")), ("#clock-cells", u32(0)), ("clock-frequency", u32(24000000)), ("clock-output-names", s("clk24mhz")), ("phandle", u32(2))], []),
      ("pl011@9000000", [("compatible", ss("arm,pl011", "arm,primecell")), ("reg", u32(0, 0x09000000, 0, 0x1000)), ("interrupts", u32(0, 1, 4)), ("clocks", u32(2, 2)), ("clock-names", ss("uartclk", "apb_pclk"))], []),
      ("pl031@9010000", [("compatible", ss("arm,pl031", "arm,primecell")), ("reg", u32(0, 0x09010000, 0, 0x1000)), ("interrupts", u32(0, 2, 4)), ("clocks", u32(2)), ("clock-names", s("apb_pclk"))], []),
    ] + ([("framebuffer@10000000", [("compatible", s("simple-framebuffer")), ("reg", u32(0, 0x10000000, 0, 0x1000000)), ("width", u32(display[0])), ("height", u32(display[1])), ("stride", u32(display[0] * 4)), ("format", s("a8r8g8b8"))], [])] if display else []) + virtio)
    return build(root)

a = machine(2, 0x10000000, "console=ttyAMA0", (0x42200000, 0x42300000), 2)
b = machine(1, 0x8000000, "", None, 0)

c = machine(1, 0x8000000, "console=tty0", None, 1, (1024, 768))
json.dump({"a": list(a), "b": list(b), "c": list(c)}, sys.stdout)

