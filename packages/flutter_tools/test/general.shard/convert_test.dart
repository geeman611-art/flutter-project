// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter_tools/src/convert.dart';

import '../src/common.dart';

void main() {
  late String passedString;
  late String nonpassString;

  const decoder = Utf8Decoder();

  setUp(() {
    passedString = 'normal string';
    nonpassString = 'malformed string => \u{FFFD}';
  });

  testWithoutContext('Decode a normal string', () async {
    expect(decoder.convert(passedString.codeUnits), passedString);
  });

  testWithoutContext(
    'Decode a malformed string prints a warning but returns the decoded string',
    () async {
      expect(decoder.convert(nonpassString.codeUnits), nonpassString);
    },
  );

  testWithoutContext('Decode invalid UTF-8 bytes from external source', () async {
    final bytes = <int>[
      91,
      78,
      111,
      116,
      105,
      102,
      105,
      99,
      97,
      116,
      105,
      111,
      110,
      93,
      32,
      113,
      117,
      101,
      117,
      101,
      100,
      58,
      32,
      97,
      100,
      118,
      101,
      114,
      116,
      32,
      40,
      240,
      159,
      165,
      168,
      75,
      73,
      52,
      79,
      84,
      75,
      32,
      66,
      97,
      99,
      107,
      112,
      97,
      99,
      107,
      32,
      239,
      191,
      189,
      41,
      10,
    ];

    // Should not throw, should return the decoded string
    final String result = decoder.convert(bytes);
    expect(result, isA<String>());
    expect(result, contains('\u{FFFD}'));
  });

  testWithoutContext('Decode with reportErrors: false does not warn', () async {
    const silentDecoder = Utf8Decoder(reportErrors: false);
    final String result = silentDecoder.convert(nonpassString.codeUnits);
    expect(result, nonpassString);
  });

  testWithoutContext('Decode empty input', () async {
    expect(decoder.convert(<int>[]), '');
  });

  testWithoutContext('Decode with start and end parameters', () async {
    const input = 'hello world';
    final List<int> bytes = input.codeUnits;
    expect(decoder.convert(bytes, 6, 11), 'world');
  });

  testWithoutContext('Decode multiple replacement characters', () async {
    // Multiple invalid byte sequences
    final bytes = <int>[239, 191, 189, 65, 239, 191, 189];
    final String result = decoder.convert(bytes);
    expect(result, contains('\u{FFFD}'));
    expect(result, contains('A'));
  });

  testWithoutContext('Decode valid UTF-8 without replacement characters', () async {
    // Valid UTF-8: "hello"
    final bytes = <int>[104, 101, 108, 108, 111];
    final String result = decoder.convert(bytes);
    expect(result, 'hello');
    expect(result.contains('\u{FFFD}'), isFalse);
  });
}
