import 'package:flutter_test/flutter_test.dart';
import 'package:kurako/src/services/playback_metadata.dart';

void main() {
  test('无效或占位码率显示未知', () {
    expect(formatMediaBitrate(null), '未知');
    expect(formatMediaBitrate(1), '未知');
    expect(formatMediaBitrate(1000), '未知');
    expect(formatMediaBitrate(double.nan), '未知');
  });

  test('可靠码率按 kbps 或 Mbps 显示', () {
    expect(formatMediaBitrate(192000), '192 kbps');
    expect(formatMediaBitrate(8 * 1000 * 1000), '8.00 Mbps');
    expect(formatMediaBitrate(12.5 * 1000 * 1000), '12.5 Mbps');
  });

  test('优先采用第一个可靠码率来源', () {
    expect(firstReliableMediaBitrate([1, null, 256000, 320000]), 256000);
  });
}
