import sys
import tempfile
import unittest
import sqlite3
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import grid_poc as grid


class GridTests(unittest.TestCase):
    def test_small_and_filtering_and_cache_modes(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "poc.sqlite"
            for size in (1, 17, 42, 1042, 2043):
                grid.prepare_database(path, size)
                for mode in ("warm", "new-connection"):
                    result = grid.measure(path, size, 3, mode)
                    self.assertEqual(result["filtered_count"]["count_value"], size - size // 17)
                    self.assertEqual(len(result["page_midpoint"]["samples_ms"]), 3)
                    self.assertEqual(result["page_end"]["returned_rows"], 0)
                    self.assertEqual(result["page_last"]["returned_rows"], 1)

    def test_corrupt_data_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "poc.sqlite"
            grid.prepare_database(path, 100)
            # sqlite3 的连接上下文管理器只提交事务、不关闭连接；Windows 上打开的
            # 句柄会让 TemporaryDirectory 清理失败，因此显式提交并关闭。
            connection = sqlite3.connect(path)
            try:
                connection.execute("UPDATE grid_poc_row SET actor='wrong' WHERE id=42")
                connection.commit()
            finally:
                connection.close()
            with self.assertRaises(ValueError):
                grid.measure(path, 100)

    def test_order_and_invalid_parameters(self):
        with self.assertRaises(ValueError):
            grid.validate_result("page_midpoint", [grid.fixture_row(1), grid.fixture_row(2)], 4)
        with self.assertRaises(ValueError):
            grid.measure(Path("unused"), 1, 0)
