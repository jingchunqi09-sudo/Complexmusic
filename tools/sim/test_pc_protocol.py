"""验证PC协议边界、噪声/拆包恢复与原模拟器映射，不需要真实串口。"""
from binascii import crc_hqx
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "gui"))
from send_sensor_frame import make_frame, decode_status, extract_status_packets
from simulator_protocol_adapter import SimulatorAdapter
from serial_tester import SerialTester


class PcProtocolTests(unittest.TestCase):
    def test_original_bow_split_and_joined_pluck(self):
        adapter = SimulatorAdapter()
        self.assertEqual(adapter.feed(bytes.fromhex("20 01 3C")), [])
        frames = adapter.feed(bytes.fromhex("00 40 40 FF 22 04 45 7F FF"))
        self.assertEqual(frames, [make_frame(4, 0, 0, 0, 0), make_frame(2, 0, 60, 129, 64),
                                  make_frame(4, 3, 0, 1, 0), make_frame(1, 3, 69, 255, 0)])
        self.assertFalse(adapter.pending)

    def test_no_duplicate_timbre_and_no_trigger_for_selection(self):
        adapter = SimulatorAdapter()
        frames = adapter.feed(bytes.fromhex("20 01 3C 01 00 7F FF 20 01 3D 01 40 7F FF"))
        self.assertEqual(len(frames), 3)
        self.assertEqual(frames[-1], make_frame(2, 0, 61, 129, 255))
        self.assertEqual(adapter.feed(bytes.fromhex("12 05 FF 10 01 FF")), [])
        self.assertEqual(adapter.feed(bytes.fromhex("11 02 3D FF")), [make_frame(8, 1, 61, 0, 0)])

    def test_all_string_stop_and_rejected_fifth_string(self):
        adapter = SimulatorAdapter()
        self.assertEqual(adapter.feed(bytes.fromhex("21 00 FF")),
                         [make_frame(2, index, 127, 0, 64) for index in range(4)])
        self.assertEqual(adapter.feed(bytes.fromhex("22 05 3C 7F FF 20 01 7F 00 40 40 FF")), [])
        self.assertEqual(adapter.counters["拒绝事件"], 2)

    def test_crc_and_resynchronization(self):
        adapter = SimulatorAdapter("standard-v1")
        body = bytes.fromhex("01 07 22 03 01 3C 40")
        valid = b"\xaa\x55" + body + crc_hqx(body, 0xFFFF).to_bytes(2, "big")
        damaged = valid[:-1] + bytes([valid[-1] ^ 1])
        frames = adapter.feed(b"noise" + damaged + valid)
        self.assertEqual(frames, [make_frame(4, 0, 0, 1, 0), make_frame(1, 0, 60, 129, 0)])
        self.assertEqual(adapter.counters["CRC错误"], 1)
        self.assertLess(len(adapter.pending), 14)

    def test_controllers_follow_live_bow_without_starting_idle_string(self):
        adapter=SimulatorAdapter()
        self.assertEqual(adapter.feed(bytes.fromhex('30 02 03 20 FF')),[])
        adapter.feed(bytes.fromhex('20 01 48 00 40 40 FF'))
        self.assertEqual(adapter.feed(bytes.fromhex('30 01 02 01 FF')),
                         [make_frame(2,0,72,129,192)])
        self.assertEqual(adapter.feed(bytes.fromhex('30 01 01 00 FF')),
                         [make_frame(2,0,72,0,192)])
        self.assertEqual(adapter.feed(bytes.fromhex('30 01 03 10 FF')),[])

    def test_partial_timeout_does_not_emit(self):
        adapter = SimulatorAdapter()
        adapter.feed(bytes.fromhex("20 01"))
        adapter.expire_partial(adapter.partial_since + 0.051)
        self.assertFalse(adapter.pending)
        self.assertEqual(adapter.counters["部分帧超时"], 1)

    def test_pc_rejects_invalid_fields(self):
        for args in [(1, 4, 60, 255, 0), (8, 0, 127, 0, 0), (7, 0, 13, 0, 0),
                     (16, 0, 6, 0, 0), (33, 3, 0, 0, 0), (99, 0, 0, 0, 0)]:
            with self.assertRaises(ValueError):
                make_frame(*args)

    def test_status_split_noise_checksum(self):
        body = bytes.fromhex("01 10 64 00 00 00 02 00 00 00")
        checksum = 0
        for byte in body:
            checksum ^= byte
        packet = b"\xd5" + body + bytes([checksum])
        pending = bytearray(b"bad" + packet[:5])
        self.assertEqual(extract_status_packets(pending), [])
        pending.extend(packet[5:])
        self.assertEqual(extract_status_packets(pending)[0]["cycles"], 100)
        with self.assertRaises(ValueError):
            decode_status(packet[:-1] + bytes([checksum ^ 1]))

    def test_gui_note_keep_preserves_selected_pitch(self):
        # 不创建窗口，只验证已发生过的重置音高问题。
        class Value:
            def __init__(self, value):
                self.value = value

            def get(self):
                return self.value

        tester = SerialTester.__new__(SerialTester)
        note = Value(72)
        pressure = Value(160)
        instrument = Value("小提琴")
        tester.string_controls = [(note, pressure, Value(64), Value(32),
                                   Value(0), instrument)]
        tester.sent_instruments = [None] * 4
        tester.sent_pressures = [None] * 4
        tester.active_bows = set()
        tester.pluck_until = [0.0]*4
        fpga_note = [55]
        frames = []

        def accept_frame(kind, index, selected_note, value, expression):
            frames.append(make_frame(kind, index, selected_note, value, expression))
            if kind == 4:
                fpga_note[0] = 55 if value == 0 else 40
            elif kind in (1, 2) and selected_note != 127:
                fpga_note[0] = selected_note
            return True

        tester.send = accept_frame
        tester.play(0, 1)
        self.assertEqual(fpga_note[0], 72)
        note.value = 127
        tester.play(0, 2)
        self.assertEqual(fpga_note[0], 72)
        self.assertEqual([frame[1] for frame in frames], [4, 1, 2])
        pressure.value = 192
        tester.play(0, 2)
        self.assertEqual([frame[1] for frame in frames[-2:]], [9, 2])
        self.assertEqual(fpga_note[0], 72)
        instrument.value = "尤克里里"
        tester.play(0, 1)
        self.assertEqual(fpga_note[0], 40)


if __name__ == "__main__":
    unittest.main()
