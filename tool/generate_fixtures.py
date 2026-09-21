#!/usr/bin/env python3
"""Regenerates the symbol fixtures used by the native decoder tests.

The fixtures are stored as module patterns (0/1 per module), not as images:
the C++ test renders them into luminance buffers at whatever scale, contrast,
rotation and canvas size a given test case needs. That keeps the repository
free of binary blobs and lets one fixture cover several test cases.

Run: tool/generate_fixtures.py   (needs the `qrcode` package for QR symbols)
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(ROOT, "test", "native", "fixtures")
ZXING_ONED = os.path.join(
    ROOT, "third_party", "zxing-cpp", "core", "src", "oned")


# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------

def runs_to_bits(runs, first_is_bar=True):
    """Expands run lengths (bar, space, bar, ...) into a bit string."""
    bits = []
    bar = first_is_bar
    for run in runs:
        bits.append(("1" if bar else "0") * run)
        bar = not bar
    return "".join(bits)


def narrow_wide_to_runs(code, count, narrow=1, wide=3):
    """Expands a narrow/wide bit table entry (MSB = first element)."""
    return [wide if (code >> (count - 1 - i)) & 1 else narrow
            for i in range(count)]


def load_zxing_patterns(header, expected):
    """Parses a `constexpr std::array<FixedPattern...> CODE_PATTERNS` table."""
    with open(os.path.join(ZXING_ONED, header), encoding="utf-8") as handle:
        text = handle.read()
    body = text.split("CODE_PATTERNS = { {", 1)[1]
    patterns = [[int(n) for n in row.split(",")]
                for row in re.findall(r"\{\s*([\d,\s]+?)\s*\}", body)]
    if len(patterns) < expected:
        raise RuntimeError(f"{header}: expected {expected} patterns, "
                           f"found {len(patterns)}")
    return patterns[:expected]


# --------------------------------------------------------------------------
# linear symbologies
# --------------------------------------------------------------------------

EAN_L = ["0001101", "0011001", "0010011", "0111101", "0100011",
         "0110001", "0101111", "0111011", "0110111", "0001011"]
EAN_G = [s[::-1].translate(str.maketrans("01", "10")) for s in EAN_L]
EAN_R = [s.translate(str.maketrans("01", "10")) for s in EAN_L]
EAN13_PARITY = ["LLLLLL", "LLGLGG", "LLGGLG", "LLGGGL", "LGLLGG",
                "LGGLLG", "LGGGLL", "LGLGLG", "LGLGGL", "LGGLGL"]
EAN8_PARITY = "LLLL"


def ean_checksum(digits):
    total = 0
    for index, digit in enumerate(reversed(digits)):
        total += digit * (3 if index % 2 == 0 else 1)
    return (10 - total % 10) % 10


def encode_ean13(value):
    digits = [int(c) for c in value]
    if len(digits) == 12:
        digits.append(ean_checksum(digits))
    assert len(digits) == 13 and digits[12] == ean_checksum(digits[:12])
    parity = EAN13_PARITY[digits[0]]
    bits = "101"
    for i, p in enumerate(parity):
        bits += (EAN_L if p == "L" else EAN_G)[digits[i + 1]]
    bits += "01010"
    for digit in digits[7:]:
        bits += EAN_R[digit]
    return bits + "101", "".join(str(d) for d in digits)


def encode_ean8(value):
    digits = [int(c) for c in value]
    if len(digits) == 7:
        digits.append(ean_checksum(digits))
    bits = "101"
    for digit in digits[:4]:
        bits += EAN_L[digit]
    bits += "01010"
    for digit in digits[4:]:
        bits += EAN_R[digit]
    return bits + "101", "".join(str(d) for d in digits)


def encode_upca(value):
    digits = [int(c) for c in value]
    if len(digits) == 11:
        digits.append(ean_checksum(digits))
    bits = "101"
    for digit in digits[:6]:
        bits += EAN_L[digit]
    bits += "01010"
    for digit in digits[6:]:
        bits += EAN_R[digit]
    return bits + "101", "".join(str(d) for d in digits)


CODE39_ALPHABET = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ-. $/+%*"
CODE39_ENCODINGS = [
    0x034, 0x121, 0x061, 0x160, 0x031, 0x130, 0x070, 0x025, 0x124, 0x064,
    0x109, 0x049, 0x148, 0x019, 0x118, 0x058, 0x00D, 0x10C, 0x04C, 0x01C,
    0x103, 0x043, 0x142, 0x013, 0x112, 0x052, 0x007, 0x106, 0x046, 0x016,
    0x181, 0x0C1, 0x1C0, 0x091, 0x190, 0x0D0, 0x085, 0x184, 0x0C4, 0x0A8,
    0x0A2, 0x08A, 0x02A, 0x094,
]


def encode_code39(value):
    bits = ""
    for char in "*" + value + "*":
        code = CODE39_ENCODINGS[CODE39_ALPHABET.index(char)]
        bits += runs_to_bits(narrow_wide_to_runs(code, 9))
        bits += "0"  # narrow inter-character gap
    return bits[:-1], value


CODABAR_ALPHABET = "0123456789-$:/.+ABCD"
CODABAR_ENCODINGS = [
    0x03, 0x06, 0x09, 0x60, 0x12, 0x42, 0x21, 0x24, 0x30, 0x48,
    0x0C, 0x18, 0x45, 0x51, 0x54, 0x15, 0x1A, 0x29, 0x0B, 0x0E,
]


def encode_codabar(value):
    bits = ""
    for char in value:
        code = CODABAR_ENCODINGS[CODABAR_ALPHABET.index(char)]
        bits += runs_to_bits(narrow_wide_to_runs(code, 7))
        bits += "0"
    return bits[:-1], value


ITF_PATTERNS = ["00110", "10001", "01001", "11000", "00101",
                "10100", "01100", "00011", "10010", "01010"]


def encode_itf(value):
    assert len(value) % 2 == 0
    runs = [1, 1, 1, 1]  # start: nnnn
    for i in range(0, len(value), 2):
        bar = ITF_PATTERNS[int(value[i])]
        space = ITF_PATTERNS[int(value[i + 1])]
        for b, s in zip(bar, space):
            runs.append(3 if b == "1" else 1)
            runs.append(3 if s == "1" else 1)
    runs += [3, 1, 1]  # stop: wnn
    return runs_to_bits(runs), value


CODE128_B = ("".join(chr(c) for c in range(32, 127)))


def encode_code128(value):
    patterns = load_zxing_patterns("ODCode128Patterns.h", 107)
    start_b = 104
    codes = [start_b] + [CODE128_B.index(c) for c in value]
    checksum = codes[0] + sum(c * (i + 1) for i, c in enumerate(codes[1:]))
    codes.append(checksum % 103)
    codes.append(106)  # stop pattern (includes the final 2-module bar)
    bits = "".join(runs_to_bits(patterns[c]) for c in codes)
    return bits + "11", value


CODE93_ALPHABET = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ-. $/+%"


def encode_code93(value):
    patterns = load_zxing_patterns("ODCode93Patterns.h", 48)
    start_stop = 47
    indices = [CODE93_ALPHABET.index(c) for c in value]

    def checksum(values, max_weight):
        total = 0
        weight = 1
        for v in reversed(values):
            total += v * weight
            weight = 1 if weight == max_weight else weight + 1
        return total % 47

    c = checksum(indices, 20)
    k = checksum(indices + [c], 15)
    codes = [start_stop] + indices + [c, k, start_stop]
    bits = "".join(runs_to_bits(patterns[i]) for i in codes)
    return bits + "1", value  # termination bar


# --------------------------------------------------------------------------
# matrix symbologies
# --------------------------------------------------------------------------

def encode_qr(value, error_correction="M"):
    import qrcode  # noqa: PLC0415 - optional dev dependency
    levels = {
        "L": qrcode.constants.ERROR_CORRECT_L,
        "M": qrcode.constants.ERROR_CORRECT_M,
        "Q": qrcode.constants.ERROR_CORRECT_Q,
        "H": qrcode.constants.ERROR_CORRECT_H,
    }
    code = qrcode.QRCode(error_correction=levels[error_correction], border=0,
                         box_size=1)
    code.add_data(value)
    code.make(fit=True)
    return ["".join("1" if cell else "0" for cell in row)
            for row in code.get_matrix()], value


# --------------------------------------------------------------------------
# fixture writing
# --------------------------------------------------------------------------

def write_fixture(name, fmt, text, rows):
    os.makedirs(OUT_DIR, exist_ok=True)
    path = os.path.join(OUT_DIR, name + ".txt")
    with open(path, "w", encoding="utf-8") as handle:
        handle.write("# generated by tool/generate_fixtures.py - do not edit\n")
        handle.write(f"format {fmt}\n")
        handle.write(f"text {text}\n")
        handle.write(f"size {len(rows[0])} {len(rows)}\n")
        for row in rows:
            handle.write(row + "\n")
    print(f"  {name}.txt  {len(rows[0])}x{len(rows)}  {fmt}  {text!r}")


LINEAR = [
    ("ean13", "ean13", encode_ean13, "590123412345"),
    ("ean8", "ean8", encode_ean8, "9638507"),
    ("upca", "upcA", encode_upca, "03600029145"),
    ("code128", "code128", encode_code128, "LBS-2026-XY"),
    ("code39", "code39", encode_code39, "FLUTTER 42"),
    ("code93", "code93", encode_code93, "LIGHTWEIGHT93"),
    ("itf", "itf", encode_itf, "1234567895"),
    ("codabar", "codabar", encode_codabar, "A123456789B"),
]

MATRIX = [
    ("qr_text", "qrCode", "HELLO FLUTTER", "M"),
    ("qr_url", "qrCode", "https://example.com/lbs?id=42", "Q"),
    ("qr_numeric", "qrCode", "8691234567890", "L"),
    ("qr_high_ec", "qrCode", "DAMAGED SYMBOL TEST", "H"),
]


def main():
    print("linear symbols:")
    for name, fmt, encoder, value in LINEAR:
        bits, text = encoder(value)
        write_fixture(name, fmt, text, [bits])

    print("matrix symbols:")
    try:
        for name, fmt, value, level in MATRIX:
            rows, text = encode_qr(value, level)
            write_fixture(name, fmt, text, rows)
    except ImportError:
        print("  skipped: `pip install qrcode` to regenerate QR fixtures",
              file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
