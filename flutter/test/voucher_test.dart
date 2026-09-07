import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nymbot/core/crypto/keys.dart';
import 'package:nymbot/core/crypto/voucher.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/ecc/api.dart';
import 'package:pointycastle/ecc/curves/secp256k1.dart';

final ECDomainParameters _secp = ECCurve_secp256k1();
BigInt get _n => _secp.n;

Uint8List _concat(List<Uint8List> parts) {
  final out = Uint8List(parts.fold(0, (a, p) => a + p.length));
  var at = 0;
  for (final p in parts) {
    out.setRange(at, at + p.length, p);
    at += p.length;
  }
  return out;
}

/// The mint half, run locally so the client half can be checked end to end
/// without a server: sign a blinded point and prove the published key did it.
({String c, String e, String s}) _mintSign(BigInt k, ECPoint blinded) {
  final cPoint = (blinded * k)!;
  final r = voucherRandomScalar();
  final r1 = (_secp.G * r)!;
  final r2 = (blinded * r)!;
  final kPoint = (_secp.G * k)!;
  final e = voucherScalar(SHA256Digest().process(_concat([
    Uint8List.fromList(voucherDleqDomain.codeUnits),
    r1.getEncoded(true),
    r2.getEncoded(true),
    kPoint.getEncoded(true),
    cPoint.getEncoded(true),
  ])));
  final s = (r + e * k) % _n;
  return (
    c: voucherPointHex(cPoint),
    e: voucherScalarHex(e),
    s: voucherScalarHex(s),
  );
}

void main() {
  test('a blind voucher round-trips and its proof checks out', () {
    final k = voucherRandomScalar();
    final keyHex = voucherPointHex((_secp.G * k)!);

    final x = randomBytes(32);
    final r = voucherRandomScalar();
    final blinded = voucherBlind(x, r);
    final sig = _mintSign(k, blinded);

    expect(
      voucherVerifyDleq(
        keyHex: keyHex,
        blindedHex: voucherPointHex(blinded),
        signatureHex: sig.c,
        e: sig.e,
        s: sig.s,
      ),
      isTrue,
    );

    // Unblinding must land on k*hashToCurve(x) — what the mint checks on
    // redemption, without ever having seen x.
    final token = voucherUnblind(
      voucherPointFromHex(sig.c),
      voucherPointFromHex(keyHex),
      r,
    );
    expect(voucherPointHex(token), voucherPointHex((voucherHashToCurve(x) * k)!));
  });

  test('a proof from a different key is refused', () {
    final k = voucherRandomScalar();
    final other = voucherRandomScalar();
    final x = randomBytes(32);
    final r = voucherRandomScalar();
    final blinded = voucherBlind(x, r);
    final sig = _mintSign(k, blinded);

    // An unprovable signature is a tagging vector, not a cosmetic problem.
    expect(
      voucherVerifyDleq(
        keyHex: voucherPointHex((_secp.G * other)!),
        blindedHex: voucherPointHex(blinded),
        signatureHex: sig.c,
        e: sig.e,
        s: sig.s,
      ),
      isFalse,
    );
  });

  test('hash-to-curve is deterministic and input-separating', () {
    final x = randomBytes(32);
    expect(voucherPointHex(voucherHashToCurve(x)),
        voucherPointHex(voucherHashToCurve(x)));
    expect(voucherPointHex(voucherHashToCurve(x)),
        isNot(voucherPointHex(voucherHashToCurve(randomBytes(32)))));
  });

  test('an amount splits into powers of two, or is refused', () {
    expect(voucherSplitAmount(7), [4, 2, 1]);
    expect(voucherSplitAmount(1), [1]);
    expect(voucherSplitAmount(4096), [4096]);
    expect(voucherSplitAmount(0), isEmpty);
    // More outputs than one request may carry.
    expect(voucherSplitAmount(4095 * 40), isNull);
  });
}
