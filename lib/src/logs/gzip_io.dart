import 'dart:io' show GZipCodec;

/// gzip where `dart:io` exists (every native platform).
List<int>? gzipBytes(List<int> bytes) => GZipCodec(level: 6).encode(bytes);
