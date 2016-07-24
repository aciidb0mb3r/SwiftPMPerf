import Basic

let s = BufferedOutputByteStream()
let a: [UInt8] = [1, 2, 3]
s <<< a
print(s.bytes)
