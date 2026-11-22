import 'dart:typed_data';

Uint8List syntheticNoteWav({int rate = 8000, int seconds = 1}) {
  final payload = rate * seconds * 2;
  final wav = ByteData(44 + payload);
  wav.setUint32(0, 0x52494646); // RIFF
  wav.setUint32(4, 36 + payload, Endian.little);
  wav.setUint32(8, 0x57415645); // WAVE
  wav.setUint32(12, 0x666d7420); // fmt
  wav.setUint32(16, 16, Endian.little);
  wav.setUint16(20, 1, Endian.little);
  wav.setUint16(22, 1, Endian.little);
  wav.setUint32(24, rate, Endian.little);
  wav.setUint32(28, rate * 2, Endian.little);
  wav.setUint16(32, 2, Endian.little);
  wav.setUint16(34, 16, Endian.little);
  wav.setUint32(36, 0x64617461); // data
  wav.setUint32(40, payload, Endian.little);
  wav.setInt16(44, 512, Endian.little);
  return wav.buffer.asUint8List();
}
