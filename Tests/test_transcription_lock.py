"""Compile only the real final-transcription entry and lock with fake ASR.

Run with TMPDIR/TMP/TEMP set to the root task directory. Does not build or run
Meeting Notes.app, resolve dependencies, or access any real meeting.
"""
import fcntl
import os
from pathlib import Path
import select
import subprocess
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[1]


class TranscriptionLockTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.build.cleanup)
        root = Path(cls.build.name)
        # Compile the production actor verbatim, with synthetic dependencies.
        source = (PROJECT / 'Sources/MeetingNotes/TranscriptionEngine.swift').read_text()
        actor = root / 'FinalTranscriptionEngine.swift'
        actor.write_text('import Foundation\nactor FinalTranscriptionEngine {' +
                         source.split('actor FinalTranscriptionEngine {', 1)[1])
        sources = [str(actor), str(PROJECT / 'Tests/TranscriptionLockFixtures.swift')]
        lock = PROJECT / 'Sources/MeetingNotes/TranscriptionLock.swift'
        if lock.exists():
            sources.append(str(lock))
        cls.binary = root / 'lock-probe'
        subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-strict-concurrency=complete',
                        '-warnings-as-errors', '-parse-as-library', '-module-cache-path',
                        str(root / 'module-cache'), *sources, '-o', str(cls.binary)],
                       check=True, timeout=120)

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        # Empty fixture file; WavFile stub checks presence only.
        (self.root / 'microphone.wav').touch()

    def child(self, root=None, **environment):
        child = subprocess.Popen([str(self.binary), str(root or self.root)],
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                 env={**os.environ, **environment}, text=True)
        def cleanup():
            if child.poll() is None:
                child.kill()
            child.wait(timeout=5)
            child.stdout.close()
            child.stderr.close()
        self.addCleanup(cleanup)
        return child

    def line(self, child):
        self.assertTrue(select.select([child.stdout], [], [], 5)[0], 'probe timeout')
        return child.stdout.readline().strip()

    def test_same_meeting_waits_across_real_processes(self):
        first = self.child()
        self.assertEqual(self.line(first), 'entered')
        second = self.child()
        self.assertEqual(self.line(first), 'done:1')
        self.assertEqual(self.line(second), 'entered')
        self.assertEqual(self.line(second), 'done:1')
        self.assertEqual(first.wait(timeout=5), 0)
        self.assertEqual(second.wait(timeout=5), 0)

    def test_independent_meetings_can_enter_while_another_is_locked(self):
        other = self.root / 'other'
        other.mkdir()
        (other / 'microphone.wav').touch()
        with (self.root / '.transcription.lock').open('w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            child = self.child(root=other)
            self.assertEqual(self.line(child), 'entered')
            self.assertEqual(self.line(child), 'done:1')

    def test_wait_is_cancellable_without_entering_either_backend(self):
        for cloud in ('0', '1'):
            with self.subTest(cloud=cloud), (self.root / '.transcription.lock').open('w') as lock:
                fcntl.flock(lock, fcntl.LOCK_EX)
                child = self.child(FIXTURE_CANCEL='1', FIXTURE_OPENAI=cloud)
                self.assertEqual(self.line(child), 'cancelled')
                self.assertEqual(child.wait(timeout=5), 0)

    def test_owner_crash_releases_lock_without_unlinking_inode(self):
        child = self.child()
        self.assertEqual(self.line(child), 'entered')
        path = self.root / '.transcription.lock'
        inode = path.stat().st_ino
        with path.open('r') as lock:
            with self.assertRaises(BlockingIOError):
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            child.kill()
            child.wait(timeout=5)
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        # Synthetic ASR's exclusive marker is deliberately not a kernel lock.
        (self.root / 'critical').unlink()
        successor = self.child()
        self.assertEqual(self.line(successor), 'entered')
        self.assertEqual(self.line(successor), 'done:1')
        self.assertEqual(path.stat().st_ino, inode)

    def test_backend_failure_releases_lock(self):
        failed = self.child(FIXTURE_ERROR='1')
        self.assertEqual(self.line(failed), 'entered')
        self.assertTrue(self.line(failed).startswith('error:'))
        self.assertEqual(failed.wait(timeout=5), 1)
        next_child = self.child()
        self.assertEqual(self.line(next_child), 'entered')
        self.assertEqual(self.line(next_child), 'done:1')

    def test_cancellation_during_backend_does_not_fall_back_and_releases_lock(self):
        for cloud in ('0', '1'):
            with self.subTest(cloud=cloud):
                child = self.child(FIXTURE_CANCEL='1', FIXTURE_OPENAI=cloud)
                self.assertEqual(self.line(child), 'entered')
                self.assertEqual(self.line(child), 'cancelled')
                self.assertEqual(child.wait(timeout=5), 0)
                with (self.root / '.transcription.lock').open('r') as lock:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def test_sensevoice_runs_under_the_same_lock(self):
        first = self.child(FIXTURE_SENSEVOICE='1')
        self.assertEqual(self.line(first), 'sensevoice')
        self.assertEqual(self.line(first), 'entered')
        second = self.child(FIXTURE_SENSEVOICE='1')
        self.assertEqual(self.line(first), 'done:1')
        self.assertEqual(self.line(second), 'sensevoice')
        self.assertEqual(self.line(second), 'entered')
        self.assertEqual(self.line(second), 'done:1')

    def test_sensevoice_error_falls_back_to_nemotron(self):
        child = self.child(FIXTURE_SENSEVOICE='1', FIXTURE_SENSEVOICE_FAIL='1')
        self.assertEqual(self.line(child), 'sensevoice-failed')
        self.assertEqual(self.line(child), 'entered')
        self.assertEqual(self.line(child), 'done:1')

    def test_sensevoice_cancellation_does_not_fall_back(self):
        child = self.child(FIXTURE_SENSEVOICE='1', FIXTURE_CANCEL='1')
        self.assertEqual(self.line(child), 'sensevoice')
        self.assertEqual(self.line(child), 'entered')
        self.assertEqual(self.line(child), 'cancelled')
        self.assertEqual(child.wait(timeout=5), 0)
        with (self.root / '.transcription.lock').open('r') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def test_cloud_error_still_falls_back_to_local(self):
        child = self.child(FIXTURE_OPENAI='1', FIXTURE_OPENAI_FAIL='1')
        self.assertEqual(self.line(child), 'cloud-failed')
        self.assertEqual(self.line(child), 'entered')
        self.assertEqual(self.line(child), 'done:1')

    def test_cancel_while_waiting_for_second_folder_releases_first(self):
        first, second = self.root / 'a', self.root / 'b'
        first.mkdir()
        second.mkdir()
        (first / 'microphone.wav').touch()
        with (second / '.transcription.lock').open('w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            child = self.child(root=first, FIXTURE_CANCEL='1', FIXTURE_SYSTEM_FOLDER=str(second))
            self.assertEqual(self.line(child), 'cancelled')
            self.assertEqual(child.wait(timeout=5), 0)
            with (first / '.transcription.lock').open('r') as released:
                fcntl.flock(released, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def test_lock_open_error_propagates_before_asr(self):
        # A symlink must not silently redirect the lease to a different inode.
        target = self.root / 'target'
        target.touch()
        (self.root / '.transcription.lock').symlink_to(target)
        child = self.child()
        self.assertTrue(self.line(child).startswith('error:'))
        self.assertEqual(child.wait(timeout=5), 1)

    def test_symlink_alias_uses_same_lock(self):
        alias = self.root / 'alias'
        alias.symlink_to(self.root, target_is_directory=True)
        with (self.root / '.transcription.lock').open('w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            child = self.child(root=alias, FIXTURE_CANCEL='1')
            self.assertEqual(self.line(child), 'cancelled')


if __name__ == '__main__':
    unittest.main()
