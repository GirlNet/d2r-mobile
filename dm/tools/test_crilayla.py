import struct
import unittest
from crilayla import decompress


def stream(bits, body_size, prefix=bytes(range(256))):
    bits += '0' * (-len(bits) % 8)
    packed = bytes(int(bits[i:i + 8], 2) for i in range(0, len(bits), 8))[::-1]
    return b'CRILAYLA' + struct.pack('<II', body_size, len(packed)) + packed + prefix


def literals(data):
    return ''.join('0' + f'{value:08b}' for value in data[::-1])


class CriLaylaTests(unittest.TestCase):
    def test_literal_prefix_and_cross_byte_reads(self):
        for n in (0, 1, 7, 8, 31, 256, 4097):
            body = bytes(i % 251 for i in range(n))
            self.assertEqual(decompress(stream(literals(body), n)), bytes(range(256)) + body)

    def test_overlap_and_non_overlap_back_references(self):
        # Decode the suffix ABC first. distance=3, length=3+3+7+1=14.
        token = '1' + f'{0:013b}' + '11' + '111' + '00001'
        result = decompress(stream(literals(b'ABC') + token, 17))
        self.assertEqual(result[256:], (b'ABC' * 6)[-17:])
        token = '1' + f'{3:013b}' + '00'  # distance=6, length=3
        self.assertEqual(decompress(stream(literals(b'ABCDEF') + token, 9))[256:], b'DEFABCDEF')

    def test_extended_lengths(self):
        # 3 + 3 + 7 + 31 + 255 + 2 = 301 repeated bytes.
        token = '1' + f'{0:013b}' + '11' + '111' + '11111' + '11111111' + f'{2:08b}'
        self.assertEqual(decompress(stream(literals(b'XXX') + token, 304))[256:], b'X' * 304)

    def test_invalid_inputs_sizes_truncation_and_references(self):
        bad = [b'', b'CRILAYLA', stream('', 1),
               stream('1' + '0' * 13 + '00', 3),
               stream(literals(b'ABC') + '1' + '0' * 13 + '11' + '111' + '11111' + '00000000', 4)]
        for data in bad:
            with self.assertRaises(ValueError):
                decompress(data)
        data = stream(literals(b'abc'), 3)
        for kwargs in (dict(expected_size=258), dict(maximum=258)):
            with self.assertRaises(ValueError):
                decompress(data, **kwargs)
        with self.assertRaises(ValueError):
            decompress(data[:-1])


if __name__ == '__main__': unittest.main()
