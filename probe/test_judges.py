#!/usr/bin/env python3
"""Tests for the judges' own logic: probe/judge_gopher.py and probe/judge_clock.py.

The judges decide what counts as "the same answer", and they have been wrong in
ways that passed: a Unix-time normalizer that could not see the Eastern
wall-clock text the session pages render, so the story passed only when both
servers ran in the same minute; and a raw-socket helper that crashed on a
refused connection instead of reporting it. A judge that is wrong is a gate
that lies, so its rules are tested here, on the host, before any kernel boots.

    python3 probe/test_judges.py
"""
import os
import socket
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import judge_gopher as G  # noqa: E402


class Normalize(unittest.TestCase):
    W = (1789600000, 1789600090)

    def test_a_unix_time_inside_the_window_is_now(self):
        self.assertEqual(G.normalize(b"created_at: 1789600050\n", self.W), b"created_at: <NOW>\n")

    def test_a_unix_time_outside_the_window_is_left_alone(self):
        # This is what makes a wrong kernel clock a DIFFERENCE.
        for t in (1789599000, 1789603650, 1758000000):
            with self.subTest(t=t):
                data = f"created_at: {t}\n".encode()
                self.assertEqual(G.normalize(data, self.W), data)

    def test_the_window_edges_are_inclusive(self):
        self.assertEqual(G.normalize(b"1789600000 1789600090", self.W), b"<NOW> <NOW>")

    def test_a_number_that_is_not_a_time_is_left_alone(self):
        for data in (b"session_id: 1789600050123", b"x21789600050", b"size 26751"):
            with self.subTest(data=data):
                self.assertEqual(G.normalize(data, self.W), data)

    def test_eastern_text_inside_the_window_is_now(self):
        text = G.eastern(1789600065)
        self.assertEqual(G.normalize(b"<td>" + text + b"</td>", self.W), b"<td><NOW-EASTERN></td>")

    def test_eastern_text_in_the_last_minute_the_window_touches(self):
        # Mid-minute: that minute's text still counts.
        w = (1789600000, 1789600110)
        self.assertEqual(G.normalize(G.eastern(1789600105), w), b"<NOW-EASTERN>")
        # And the edge an off-by-one misses: a window that ends EXACTLY on a
        # minute, with the request stamped in that very second.
        assert 1789600020 % 60 == 0
        w = (1789600000, 1789600020)
        self.assertEqual(G.normalize(G.eastern(1789600020), w), b"<NOW-EASTERN>")

    def test_eastern_text_outside_the_window_is_left_alone(self):
        staged = G.eastern(1758000000)
        self.assertEqual(G.normalize(staged, self.W), staged)
        an_hour_off = G.eastern(1789600050 + 3600)
        self.assertEqual(G.normalize(an_hour_off, self.W), an_hour_off)


class MoreNormalize(unittest.TestCase):
    W = (1789600000, 1789600090)

    def test_rfc3339_inside_the_window_is_now(self):
        # 1789600050 is 2026-09-16T23:07:30Z.
        self.assertEqual(G.normalize(b"at 2026-09-16T23:07:30Z.", self.W), b"at <NOW-RFC3339>.")

    def test_rfc3339_outside_the_window_is_left_alone(self):
        data = b"at 2026-09-16T22:07:30Z and 2025-09-16T05:20:00Z"
        self.assertEqual(G.normalize(data, self.W), data)

    def test_a_session_minted_in_the_window_loses_its_time_and_mac(self):
        cookie = G.mint_session("1", 1789600050).encode()
        self.assertEqual(G.normalize(cookie, self.W), b"gopher_auth=MQ.<NOW>.<MAC>")

    def test_a_session_minted_outside_the_window_keeps_both(self):
        cookie = G.mint_session("1", 1758000000).encode()
        self.assertEqual(G.normalize(cookie, self.W), cookie)


class Sessions(unittest.TestCase):
    def test_the_minted_format_is_signsessions(self):
        # Checked once against users.signSession itself, for this secret.
        self.assertEqual(G.mint_session("1", 1789600000),
                         "gopher_auth=MQ.1789600000.b89_jCbiAAoR-wSNNVBb2hogDPNxtibiP_8VnsWvtUs")

    def test_a_forgery_claims_one_id_with_anothers_mac(self):
        real2 = G.mint_session("2", 1789600000)
        forged = G.forge_session("1", "2", 1789600000)
        self.assertTrue(forged.startswith("gopher_auth=MQ."))
        self.assertEqual(forged.split(".", 1)[1], real2.split(".", 1)[1])
        self.assertNotEqual(forged, G.mint_session("1", 1789600000))


class Jar(unittest.TestCase):
    def test_every_cookie_is_kept(self):
        a = {"headers": {"set-cookie": "gopher_uid=1; Path=/\ngopher_auth=MQ.1.x; Path=/"}}
        self.assertEqual(G.update_jar(a, {}), {"gopher_uid": "1", "gopher_auth": "MQ.1.x"})

    def test_max_age_zero_removes(self):
        a = {"headers": {"set-cookie": "gopher_uid=; Path=/; Max-Age=0\ngopher_auth=; Path=/; Max-Age=0"}}
        self.assertEqual(G.update_jar(a, {"gopher_uid": "1", "gopher_auth": "x", "other": "y"}), {"other": "y"})

    def test_the_jar_becomes_one_cookie_header(self):
        s = G.step("x", "GET", "/", G.JAR)
        c = G.with_jar(s, {"gopher_uid": "1", "gopher_auth": "MQ.1.x"})["cookie"]
        self.assertEqual(c, "gopher_uid=1; gopher_auth=MQ.1.x")
        self.assertIsNone(G.with_jar(s, {})["cookie"])

    def test_minted_placeholders_resolve_on_both_sides(self):
        s = G.step("x", "GET", "/", G.FRESH)
        self.assertEqual(G.with_jar(s, {}, {G.FRESH: "gopher_auth=abc"})["cookie"], "gopher_auth=abc")


class Eastern(unittest.TestCase):
    """judge_gopher restates angry-gopher's formatEastern with zoneinfo. These
    are the cases that format has to get right. Each expected string was worked
    out by hand from a UTC time whose Unix value calendar.timegm confirms —
    EDT is UTC-4, EST is UTC-5, and in 2026 the change is on 8 March."""

    def test_daylight_time(self):
        self.assertEqual(G.eastern(1758000000), "Sep 16, 2025 · 1:20 AM EDT".encode())

    def test_standard_time(self):
        # 2026-01-15 17:00 UTC is noon in New York, in winter.
        self.assertEqual(G.eastern(1768496400), "Jan 15, 2026 · 12:00 PM EST".encode())

    def test_midnight_is_twelve_am(self):
        # 2026-01-15 05:00 UTC is midnight EST.
        self.assertEqual(G.eastern(1768453200), "Jan 15, 2026 · 12:00 AM EST".encode())

    def test_the_spring_change(self):
        # 2026-03-08: 06:59 UTC is 1:59 AM EST; 07:00 UTC is 3:00 AM EDT.
        self.assertEqual(G.eastern(1772953140), "Mar 8, 2026 · 1:59 AM EST".encode())
        self.assertEqual(G.eastern(1772953200), "Mar 8, 2026 · 3:00 AM EDT".encode())


class Cookies(unittest.TestCase):
    def test_a_set_cookie_replaces_the_jar(self):
        a = {"headers": {"set-cookie": "gopher_uid=p1; Path=/; Max-Age=31536000; HttpOnly; SameSite=Lax"}}
        self.assertEqual(G.cookie_from(a, None), "gopher_uid=p1")
        self.assertEqual(G.cookie_from(a, "gopher_uid=9"), "gopher_uid=p1")

    def test_no_set_cookie_keeps_the_jar(self):
        self.assertEqual(G.cookie_from({"headers": {}}, "gopher_uid=p2"), "gopher_uid=p2")
        self.assertIsNone(G.cookie_from({"error": "refused"}, None))

    def test_a_different_cookie_is_not_the_identity(self):
        a = {"headers": {"set-cookie": "gopher_auth=abc; Path=/"}}
        self.assertEqual(G.cookie_from(a, "gopher_uid=p1"), "gopher_uid=p1")

    def test_with_jar_only_touches_the_placeholder(self):
        s = G.step("x", "GET", "/", G.JAR)
        self.assertEqual(G.with_jar(s, "gopher_uid=p1")["cookie"], "gopher_uid=p1")
        fixed = G.step("x", "GET", "/", G.P1)
        self.assertIs(G.with_jar(fixed, "gopher_uid=p1"), fixed)


class Differences(unittest.TestCase):
    def answer(self, **kw):
        base = {"status": 200, "headers": {"content-type": "text/html"}, "body": b"hi",
                "guest_exit": 1, "window": (0, 0), "serial": ""}
        base.update(kw)
        return base

    def test_equal_answers_agree(self):
        c = G.case("x", "GET", "/")
        self.assertEqual(G.differences(c, self.answer(), self.answer()), [])

    def test_each_kind_of_difference_is_reported(self):
        c = G.case("x", "GET", "/")
        cases = [
            (dict(status=404), "status"),
            (dict(headers={"content-type": "text/plain"}), "content-type"),
            (dict(headers={"content-type": "text/html", "location": "/play"}), "location"),
            (dict(body=b"ho"), "body differs"),
            (dict(guest_exit=3, serial="FAIL: x"), "the guest exited 3"),
        ]
        for change, want in cases:
            with self.subTest(want=want):
                diffs = G.differences(c, self.answer(**change), self.answer())
                self.assertTrue(any(want in d for d in diffs), diffs)

    def test_a_server_that_did_not_answer_is_named(self):
        c = G.case("x", "GET", "/")
        self.assertIn("kernel", G.differences(c, {"error": "x"}, self.answer())[0])
        self.assertIn("LINUX", G.differences(c, self.answer(), {"error": "x"})[0])

    def test_the_first_difference_is_located(self):
        self.assertIn("byte 3", G.first_difference(b"abcdef", b"abcXef"))
        self.assertIn("byte 3", G.first_difference(b"abc", b"abcdef"))

    def test_version_is_compared_field_by_field(self):
        m = b'{"result":"success","version":"0.1-zig","commit":"bare-metal","rejects":{},"mem":{"live_bytes":1}}'
        l = b'{"result":"success","version":"0.1-zig","commit":"dev","rejects":{},"mem":{"live_bytes":9}}'
        self.assertEqual(G.version_differences(m, l), [])
        wrong = m.replace(b"bare-metal", b"dev")
        self.assertTrue(G.version_differences(wrong, l))
        self.assertTrue(G.version_differences(m, l.replace(b'"rejects":{}', b'"rejects":{"x":1}')))


class RawSocket(unittest.TestCase):
    def test_a_refused_connection_is_an_error_not_a_crash(self):
        port = G.free_port()  # nothing listens there
        self.assertIn("error", G.ask_raw(port, b"GET / HTTP/1.1\r\n\r\n"))

    def test_bytes_come_back_until_close(self):
        srv = socket.socket()
        srv.bind(("127.0.0.1", 0))
        srv.listen(1)
        port = srv.getsockname()[1]

        import threading

        def serve():
            c, _ = srv.accept()
            c.recv(100)
            c.sendall(b"hello")
            c.close()

        t = threading.Thread(target=serve)
        t.start()
        got = G.ask_raw(port, b"x")
        t.join()
        srv.close()
        self.assertEqual(got["body"], b"hello")


class Traces(unittest.TestCase):
    LOG = ("  request 1: GET / -> ok (base: 70 live bytes)\n"
           "    request heap: 58498 bytes\n"
           "  request 2: GET /nope -> ok (base: 72 live bytes)\n"
           "    request heap: 1200 bytes\n")

    def test_the_heaps_are_read_from_the_serial_log(self):
        self.assertEqual(G.base_heap_trace(self.LOG), [70, 72])
        self.assertEqual(G.request_heap_trace(self.LOG), [58498, 1200])


class ClockJudge(unittest.TestCase):
    def verdict(self, text, *args):
        with tempfile.NamedTemporaryFile("w", suffix=".out", delete=False) as f:
            f.write(text)
        try:
            p = subprocess.run([sys.executable, os.path.join(HERE, "judge_clock.py"), f.name, *args],
                               capture_output=True, text=True)
        finally:
            os.remove(f.name)
        return p.returncode, p.stdout

    def test_a_consistent_reading_inside_the_host_window_passes(self):
        code, out = self.verdict("tsc_hz 2494134000\nunix 1789600584\ncivil 2026-9-16 23:16:24\n",
                                 "1789600582", "1789600591")
        self.assertEqual(code, 0, out)
        self.assertIn("same instant", out)
        self.assertIn("within the host's clock", out)
        self.assertNotIn("FAIL civil", out)

    def test_civil_and_unix_that_disagree_fail(self):
        code, out = self.verdict("tsc_hz 2494000000\nunix 1789600584\ncivil 2026-9-16 23:16:25\n",
                                 "1789600582", "1789600591")
        self.assertEqual(code, 1)
        self.assertIn("FAIL civil", out)

    def test_a_reading_outside_the_host_window_fails(self):
        code, out = self.verdict("tsc_hz 2494000000\nunix 1789604184\ncivil 2026-9-17 0:16:24\n",
                                 "1789600582", "1789600591")
        self.assertEqual(code, 1)
        self.assertIn("outside the host's clock", out)

    def test_a_pinned_boot_must_read_just_after_its_base(self):
        ok = "tsc_hz 2494134000\nunix 1583020801\ncivil 2020-3-1 0:0:1\n"
        code, out = self.verdict(ok, "0", "0", "2020-02-29T23:59:59")
        self.assertEqual(code, 0, out)
        self.assertIn("2 s after the pinned", out)
        late = "tsc_hz 2494000000\nunix 1583024400\ncivil 2020-3-1 1:0:0\n"
        code, out = self.verdict(late, "0", "0", "2020-02-29T23:59:59")
        self.assertEqual(code, 1)
        self.assertIn("not just after the pinned", out)

    def test_a_missing_line_fails(self):
        code, out = self.verdict("tsc_hz 2494000000\n", "0", "0")
        self.assertNotEqual(code, 0)


class Resolution(unittest.TestCase):
    """FAT16 stores a modification time in whole EVEN seconds; ext4 stores
    nanoseconds. Wherever a story judges the ORDER of two writes, it has to put
    them further apart than the coarser clock's tick — otherwise the judge is
    demanding that FAT16 be ext4, and the failure it reports is its own."""

    FAT16_TICK = 2.0

    def test_the_second_conversation_is_created_a_tick_later(self):
        by_name = {s["name"]: s for s in G.MEMBER_STORY}
        self.assertGreater(by_name["a new topic"]["settle"], self.FAT16_TICK)

    def test_recent_activity_comes_after_both_conversations_are_written(self):
        # The order it prints is the thing being judged, so it must be asked
        # last of the three.
        names = [s["name"] for s in G.MEMBER_STORY]
        self.assertLess(names.index("a message in it"), names.index("recent activity"))
        self.assertLess(names.index("a new topic"), names.index("a message in it"))

    def test_every_step_carries_the_field_the_runner_reads(self):
        for s in G.MEMBER_STORY + G.SEQUENCE:
            self.assertIn("settle", s, s["name"])

    def test_a_story_waits_no_longer_than_it_has_to(self):
        # A settle is dead time on both sides, twice. If this starts climbing,
        # something is being papered over with sleep.
        total = sum(s["settle"] for s in G.MEMBER_STORY + G.SEQUENCE)
        self.assertLessEqual(total, 6.0)


if __name__ == "__main__":
    unittest.main(verbosity=1)
