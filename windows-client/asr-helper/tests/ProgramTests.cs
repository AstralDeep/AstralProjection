using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace AstralSpeechHelper.Tests
{
    [TestClass]
    public sealed class ProgramTests
    {
        private sealed class TestFrame
        {
            internal TestFrame(FrameKind kind, ushort recognitionId, byte[] payload)
            {
                Kind = kind;
                RecognitionId = recognitionId;
                Payload = payload;
            }

            internal FrameKind Kind { get; }

            internal ushort RecognitionId { get; }

            internal byte[] Payload { get; }
        }

        private sealed class FakeSession : IRecognitionSession
        {
            internal HostCapabilityException? ProbeFailure { get; set; }

            internal int Probes { get; private set; }

            internal List<ushort> Starts { get; } = new List<ushort>();

            internal List<ushort> Feeds { get; } = new List<ushort>();

            internal List<ushort> Stops { get; } = new List<ushort>();

            internal int Disposals { get; private set; }

            public void ProveReady()
            {
                Probes++;
                if (ProbeFailure != null)
                {
                    throw ProbeFailure;
                }
            }

            public void Start(ushort recognitionId) => Starts.Add(recognitionId);

            public void Feed(ushort recognitionId, byte[] pcm) => Feeds.Add(recognitionId);

            public void Stop(ushort recognitionId) => Stops.Add(recognitionId);

            public void Dispose() => Disposals++;
        }

        private sealed class FakeHostProbe : IRecognitionHostProbe
        {
            private readonly string recognizerId;

            internal FakeHostProbe(string recognizerId = "fake-en-US")
            {
                this.recognizerId = recognizerId;
            }

            internal int Probes { get; private set; }

            public string ProveReady()
            {
                Probes++;
                return recognizerId;
            }
        }

        private sealed class FakeRecognitionEngine : IRecognitionEngine
        {
            private RecognitionTextHandler? recognized;
            private RecognitionCompletedHandler? completed;
            private RecognitionTextHandler? retainedRecognized;

            internal bool ThrowOnStart { get; set; }

            internal bool CompleteWithErrorOnCancel { get; set; }

            internal bool ThrowOnCancel { get; set; }

            internal bool Started { get; private set; }

            internal bool Cancelled { get; private set; }

            internal bool Disposed { get; private set; }

            internal BoundedAudioStream? Audio { get; private set; }

            public event RecognitionTextHandler? Recognized
            {
                add
                {
                    recognized += value;
                    retainedRecognized = value;
                }
                remove => recognized -= value;
            }

            public event RecognitionCompletedHandler? Completed
            {
                add => completed += value;
                remove => completed -= value;
            }

            public void SetInput(BoundedAudioStream audio) => Audio = audio;

            public void Start()
            {
                if (ThrowOnStart)
                {
                    throw new InvalidOperationException("start failed");
                }

                Started = true;
            }

            public void Cancel()
            {
                Cancelled = true;
                if (ThrowOnCancel)
                {
                    throw new InvalidOperationException("already completed");
                }

                if (CompleteWithErrorOnCancel)
                {
                    completed?.Invoke(this, new InvalidOperationException("cancelled"));
                }
            }

            public void Dispose() => Disposed = true;

            internal void EmitRecognized(string text) => recognized?.Invoke(this, text);

            internal void EmitLateRecognized(string text) => retainedRecognized?.Invoke(this, text);

            internal void EmitCompleted(Exception? error) => completed?.Invoke(this, error);
        }

        private static TestFrame F(FrameKind kind, ushort recognitionId, byte[] payload)
        {
            return new TestFrame(kind, recognitionId, payload);
        }

        private static byte[] Frames(params TestFrame[] values)
        {
            using (MemoryStream stream = new MemoryStream())
            {
                foreach (TestFrame value in values)
                {
                    FrameProtocol.Write(
                        stream,
                        value.Kind,
                        value.RecognitionId,
                        value.Payload);
                }

                return stream.ToArray();
            }
        }

        private static TestFrame Start(ushort recognitionId)
        {
            return F(
                FrameKind.Start,
                recognitionId,
                FrameProtocol.Utf8(Program.StartPayload));
        }

        private static TestFrame Shutdown()
        {
            return F(FrameKind.Shutdown, 0, Array.Empty<byte>());
        }

        private static RecognizerCapability Capability(
            string id,
            string culture,
            params RecognitionAudioFormat[] formats)
        {
            return new RecognizerCapability(id, culture, formats);
        }

        [TestMethod]
        public void MainRejectsInvalidProcessArguments()
        {
            Assert.AreEqual(64, Program.Main(Array.Empty<string>()));
        }

        [TestMethod]
        public void RunAcceptsRecognizerNativeAudioFormatAndRejectsLegacyRate()
        {
            FakeSession nativeSession = new FakeSession();
            byte[] nativeInput = Frames(Start(17), Shutdown());
            Assert.AreEqual(
                0,
                Program.Run(
                    new MemoryStream(nativeInput),
                    new MemoryStream(),
                    _ => nativeSession));
            CollectionAssert.AreEqual(new ushort[] { 17 }, nativeSession.Starts);

            FakeSession legacySession = new FakeSession();
            byte[] legacyInput = Frames(
                F(
                    FrameKind.Start,
                    18,
                    FrameProtocol.Utf8(
                        "{\"locale\":\"en-US\",\"sample_rate\":48000,\"channels\":1}")));
            Assert.AreEqual(
                65,
                Program.Run(
                    new MemoryStream(legacyInput),
                    new MemoryStream(),
                    _ => legacySession));
            Assert.AreEqual(0, legacySession.Starts.Count);
        }

        [TestMethod]
        public void RunProvesHostBeforeWritingReady()
        {
            FakeSession session = new FakeSession();
            MemoryStream output = new MemoryStream();
            Assert.AreEqual(
                65,
                Program.Run(new MemoryStream(), output, _ => session));
            Assert.AreEqual(1, session.Probes);
            output.Position = 0;
            HelperFrame ready = FrameProtocol.Read(output);
            Assert.AreEqual(FrameKind.Ready, ready.Kind);
            Assert.AreEqual(0, ready.RecognitionId);
            Assert.AreEqual(Program.ReadyPayload, FrameProtocol.DecodeUtf8(ready.Payload));
        }

        [TestMethod]
        public void RunWithHostCapabilityFailureWritesNoReady()
        {
            foreach (HostCapabilityFailure failure in Enum.GetValues(typeof(HostCapabilityFailure)))
            {
                FakeSession session = new FakeSession
                {
                    ProbeFailure = new HostCapabilityException(failure, failure.ToString()),
                };
                MemoryStream output = new MemoryStream();
                Assert.AreEqual(
                    Program.HostCapabilityExitCode,
                    Program.Run(new MemoryStream(), output, _ => session));
                Assert.AreEqual(0, output.Length);
                Assert.AreEqual(1, session.Disposals);
            }
        }

        [TestMethod]
        public void RunRejectsStopBeforeStart()
        {
            Assert.AreEqual(
                65,
                Program.Run(
                    new MemoryStream(
                        Frames(F(FrameKind.Stop, 1, Array.Empty<byte>()))),
                    new MemoryStream(),
                    _ => new FakeSession()));
        }

        [TestMethod]
        public void RunRejectsRepeatedStart()
        {
            Assert.AreEqual(
                65,
                Program.Run(
                    new MemoryStream(Frames(Start(1), Start(2))),
                    new MemoryStream(),
                    _ => new FakeSession()));
        }

        [TestMethod]
        public void RunRejectsMismatchedCyclesAndEmptyPcm()
        {
            FakeSession mismatchedSession = new FakeSession();
            Assert.AreEqual(
                65,
                Program.Run(
                    new MemoryStream(
                        Frames(Start(7), F(FrameKind.Pcm, 8, new byte[] { 0, 0 }))),
                    new MemoryStream(),
                    _ => mismatchedSession));
            Assert.AreEqual(0, mismatchedSession.Feeds.Count);

            FakeSession emptySession = new FakeSession();
            Assert.AreEqual(
                65,
                Program.Run(
                    new MemoryStream(
                        Frames(Start(7), F(FrameKind.Pcm, 7, Array.Empty<byte>()))),
                    new MemoryStream(),
                    _ => emptySession));
            Assert.AreEqual(0, emptySession.Feeds.Count);

            FakeSession mismatchedStopSession = new FakeSession();
            Assert.AreEqual(
                65,
                Program.Run(
                    new MemoryStream(
                        Frames(Start(7), F(FrameKind.Stop, 8, Array.Empty<byte>()))),
                    new MemoryStream(),
                    _ => mismatchedStopSession));
            Assert.AreEqual(0, mismatchedStopSession.Stops.Count);
        }

        [TestMethod]
        public void RunRejectsTruncatedActiveInput()
        {
            byte[] start = Frames(Start(22));
            byte[] truncated = new byte[start.Length + 2];
            Buffer.BlockCopy(start, 0, truncated, 0, start.Length);
            truncated[start.Length] = (byte)'A';
            Assert.AreEqual(
                65,
                Program.Run(
                    new MemoryStream(truncated),
                    new MemoryStream(),
                    _ => new FakeSession()));
        }

        [TestMethod]
        public void RunSerializesPersistentCyclesWithStoppedAcknowledgements()
        {
            FakeSession session = new FakeSession();
            byte[] input = Frames(
                Start(ushort.MaxValue),
                F(FrameKind.Pcm, ushort.MaxValue, new byte[] { 0, 0 }),
                F(FrameKind.Stop, ushort.MaxValue, Array.Empty<byte>()),
                Start(1),
                F(FrameKind.Pcm, 1, new byte[] { 1, 1 }),
                F(FrameKind.Stop, 1, Array.Empty<byte>()),
                Shutdown());
            MemoryStream output = new MemoryStream();
            Assert.AreEqual(
                0,
                Program.Run(new MemoryStream(input), output, _ => session));
            CollectionAssert.AreEqual(
                new ushort[] { ushort.MaxValue, 1 },
                session.Starts);
            CollectionAssert.AreEqual(
                new ushort[] { ushort.MaxValue, 1 },
                session.Feeds);
            CollectionAssert.AreEqual(
                new ushort[] { ushort.MaxValue, 1 },
                session.Stops);
            Assert.AreEqual(1, session.Disposals);

            output.Position = 0;
            Assert.AreEqual(FrameKind.Ready, FrameProtocol.Read(output).Kind);
            HelperFrame firstStopped = FrameProtocol.Read(output);
            Assert.AreEqual(FrameKind.Stopped, firstStopped.Kind);
            Assert.AreEqual(ushort.MaxValue, firstStopped.RecognitionId);
            Assert.AreEqual(0, firstStopped.Payload.Length);
            HelperFrame secondStopped = FrameProtocol.Read(output);
            Assert.AreEqual(FrameKind.Stopped, secondStopped.Kind);
            Assert.AreEqual(1, secondStopped.RecognitionId);
            Assert.AreEqual(output.Length, output.Position);
        }

        [TestMethod]
        public void RunStopsActiveCycleOnShutdownWithoutStoppedAcknowledgement()
        {
            FakeSession session = new FakeSession();
            byte[] input = Frames(
                Start(4),
                F(FrameKind.Pcm, 4, new byte[] { 0, 0 }),
                Shutdown());
            MemoryStream output = new MemoryStream();
            Assert.AreEqual(
                0,
                Program.Run(new MemoryStream(input), output, _ => session));
            CollectionAssert.AreEqual(new ushort[] { 4 }, session.Stops);
            output.Position = 0;
            FrameProtocol.Read(output);
            Assert.AreEqual(output.Length, output.Position);
        }

        [TestMethod]
        public void CapabilitySelectorRequiresExactLocaleAndRequiredFormat()
        {
            HostCapabilityException localeFailure = Assert.ThrowsExactly<HostCapabilityException>(
                () => RecognitionCapabilitySelector.SelectRequired(
                    new[]
                    {
                        Capability(
                            "wrong-case",
                            "en-us",
                            new RecognitionAudioFormat(16000, 16, 1)),
                    }));
            Assert.AreEqual(
                HostCapabilityFailure.ExactLocaleUnavailable,
                localeFailure.Failure);

            HostCapabilityException formatFailure = Assert.ThrowsExactly<HostCapabilityException>(
                () => RecognitionCapabilitySelector.SelectRequired(
                    new[]
                    {
                        Capability(
                            "legacy-format",
                            "en-US",
                            new RecognitionAudioFormat(48000, 16, 1)),
                    }));
            Assert.AreEqual(
                HostCapabilityFailure.RequiredAudioFormatUnavailable,
                formatFailure.Failure);
        }

        [TestMethod]
        public void CapabilityProbeSelectsDeterministicallyAndClassifiesConstructionFailure()
        {
            RecognizerCapability[] capabilities = new[]
            {
                Capability(
                    "z-recognizer",
                    "en-US",
                    new RecognitionAudioFormat(16000, 16, 1)),
                Capability(
                    "a-recognizer",
                    "en-US",
                    new RecognitionAudioFormat(16000, 16, 1)),
            };
            string? constructed = null;
            SystemRecognitionHostProbe successfulProbe = new SystemRecognitionHostProbe(
                () => capabilities,
                id => constructed = id);
            Assert.AreEqual("a-recognizer", successfulProbe.ProveReady());
            Assert.AreEqual("a-recognizer", constructed);

            InvalidOperationException constructionFailure = new InvalidOperationException("boom");
            SystemRecognitionHostProbe failingProbe = new SystemRecognitionHostProbe(
                () => capabilities,
                _ => throw constructionFailure);
            HostCapabilityException failure = Assert.ThrowsExactly<HostCapabilityException>(
                () => failingProbe.ProveReady());
            Assert.AreEqual(
                HostCapabilityFailure.RecognizerConstructionFailed,
                failure.Failure);
            Assert.AreSame(constructionFailure, failure.InnerException);
        }

        [TestMethod]
        public void CapabilityProbeGuardClausesRemainDeterministic()
        {
            Assert.ThrowsExactly<ArgumentNullException>(() =>
                RecognitionCapabilitySelector.SelectRequired(null!));
            Assert.IsNotNull(new SystemRecognitionHostProbe());

            RecognizerCapability[] capabilities = new[]
            {
                Capability(
                    "fake-en-US",
                    "en-US",
                    new RecognitionAudioFormat(16000, 16, 1)),
            };
            HostCapabilityException expected = new HostCapabilityException(
                HostCapabilityFailure.RecognizerConstructionFailed,
                "expected");
            SystemRecognitionHostProbe probe = new SystemRecognitionHostProbe(
                () => capabilities,
                _ => throw expected);
            Assert.AreSame(
                expected,
                Assert.ThrowsExactly<HostCapabilityException>(() => probe.ProveReady()));
        }

        [TestMethod]
        public void SystemRecognitionEngineDelegatesDeterministicOperations()
        {
            BoundedAudioStream? suppliedAudio = null;
            int starts = 0;
            int cancels = 0;
            int disposals = 0;
            SystemRecognitionEngine engine = new SystemRecognitionEngine(
                audio => suppliedAudio = audio,
                () => starts++,
                () => cancels++,
                () => disposals++);
            using (BoundedAudioStream audio = new BoundedAudioStream())
            {
                engine.SetInput(audio);
                engine.Start();
                engine.Cancel();
                engine.Dispose();
                Assert.AreSame(audio, suppliedAudio);
            }

            Assert.AreEqual(1, starts);
            Assert.AreEqual(1, cancels);
            Assert.AreEqual(1, disposals);
        }

        [TestMethod]
        public void SystemRecognitionEngineForwardsNativeEventsDeterministically()
        {
            SystemRecognitionEngine engine = new SystemRecognitionEngine(
                _ => { },
                () => { },
                () => { },
                () => { });
            string? recognized = null;
            Exception? completed = null;
            engine.Recognized += (_, text) => recognized = text;
            engine.Completed += (_, error) => completed = error;

            Assembly speechAssembly = Assembly.Load("System.Speech");
            Type recognizedArgsType = speechAssembly.GetType(
                "System.Speech.Recognition.SpeechRecognizedEventArgs",
                true)
                ?? throw new InvalidOperationException("recognized args type was not found");
            Type completedArgsType = speechAssembly.GetType(
                "System.Speech.Recognition.RecognizeCompletedEventArgs",
                true)
                ?? throw new InvalidOperationException("completed args type was not found");
            object recognizedArgs = Activator.CreateInstance(
                    recognizedArgsType,
                    BindingFlags.Instance | BindingFlags.NonPublic,
                    null,
                    new object[] { null! },
                    null)
                ?? throw new InvalidOperationException("recognized args were not created");
            InvalidOperationException expected = new InvalidOperationException("completed");
            object completedArgs = Activator.CreateInstance(
                    completedArgsType,
                    BindingFlags.Instance | BindingFlags.NonPublic,
                    null,
                    new object[]
                    {
                        null!,
                        false,
                        false,
                        false,
                        TimeSpan.Zero,
                        expected,
                        false,
                        null!,
                    },
                    null)
                ?? throw new InvalidOperationException("completed args were not created");
            MethodInfo recognizedMethod = typeof(SystemRecognitionEngine).GetMethod(
                "OnSpeechRecognized",
                BindingFlags.Instance | BindingFlags.NonPublic)
                ?? throw new InvalidOperationException("recognized handler was not found");
            MethodInfo completedMethod = typeof(SystemRecognitionEngine).GetMethod(
                "OnRecognizeCompleted",
                BindingFlags.Instance | BindingFlags.NonPublic)
                ?? throw new InvalidOperationException("completed handler was not found");

            recognizedMethod.Invoke(engine, new object[] { engine, recognizedArgs });
            completedMethod.Invoke(engine, new object[] { engine, completedArgs });
            Assert.AreEqual(string.Empty, recognized);
            Assert.AreSame(expected, completed);
        }

        [TestMethod]
        public void RecognitionCycleWriterRejectsInvalidLifecycleAndIgnoresEmptyText()
        {
            MemoryStream output = new MemoryStream();
            RecognitionCycleWriter writer = new RecognitionCycleWriter(output, new object());
            Assert.ThrowsExactly<InvalidDataException>(() => writer.Begin(0));
            writer.Begin(20);
            Assert.ThrowsExactly<InvalidDataException>(() => writer.Begin(21));
            Assert.ThrowsExactly<InvalidDataException>(() => writer.Invalidate(21));
            writer.WriteRecognizedText(20, "   ");
            Assert.AreEqual(0, output.Length);
            writer.Invalidate(20);
        }

        [TestMethod]
        public void RecognitionSessionGuardClausesAndFactoryFailureAreRecoverable()
        {
            using (RecognitionSession defaultSession = new RecognitionSession(new MemoryStream()))
            {
            }
            Assert.ThrowsExactly<ArgumentException>(() =>
                RecognitionSession.CreateSystemEngine("__astral_missing_recognizer__"));

            using (RecognitionSession emptyRecognizer = new RecognitionSession(
                new MemoryStream(),
                new FakeHostProbe(string.Empty),
                _ => new FakeRecognitionEngine()))
            {
                HostCapabilityException emptyFailure = Assert.ThrowsExactly<HostCapabilityException>(
                    () => emptyRecognizer.ProveReady());
                Assert.AreEqual(
                    HostCapabilityFailure.RecognizerConstructionFailed,
                    emptyFailure.Failure);
            }

            using (RecognitionSession notReady = new RecognitionSession(
                new MemoryStream(),
                new FakeHostProbe(),
                _ => new FakeRecognitionEngine()))
            {
                Assert.ThrowsExactly<InvalidDataException>(() => notReady.Start(1));
            }

            using (RecognitionSession guarded = new RecognitionSession(
                new MemoryStream(),
                new FakeHostProbe(),
                _ => throw new InvalidOperationException("factory failed")))
            {
                guarded.ProveReady();
                Assert.ThrowsExactly<InvalidDataException>(() => guarded.ProveReady());
                Assert.ThrowsExactly<InvalidDataException>(() => guarded.Start(0));
                Assert.ThrowsExactly<InvalidOperationException>(() => guarded.Start(1));
            }
        }

        [TestMethod]
        public void RecognitionSessionRejectsOverlappingAndMismatchedOperations()
        {
            FakeRecognitionEngine engine = new FakeRecognitionEngine();
            RecognitionSession session = new RecognitionSession(
                new MemoryStream(),
                new FakeHostProbe(),
                _ => engine);
            session.ProveReady();
            session.Start(40);
            Assert.ThrowsExactly<InvalidDataException>(() => session.Start(41));
            session.Feed(40, new byte[] { 1, 2 });
            Assert.AreEqual(2, engine.Audio?.QueuedBytes);
            Assert.ThrowsExactly<InvalidDataException>(() =>
                session.Feed(41, new byte[] { 1, 2 }));
            Assert.ThrowsExactly<InvalidDataException>(() => session.Stop(41));
            session.Dispose();
            Assert.IsTrue(engine.Cancelled);
            Assert.IsTrue(engine.Disposed);
            Assert.ThrowsExactly<InvalidDataException>(() =>
                session.Feed(40, new byte[] { 1, 2 }));
            Assert.ThrowsExactly<InvalidDataException>(() => session.Stop(40));
        }

        [TestMethod]
        public void RunRejectsMalformedShutdownUnexpectedKindAndSessionFailures()
        {
            Assert.AreEqual(
                65,
                Program.Run(
                    new MemoryStream(
                        Frames(F(FrameKind.Shutdown, 0, new byte[] { 1 }))),
                    new MemoryStream(),
                    _ => new FakeSession()));
            Assert.AreEqual(
                65,
                Program.Run(
                    new MemoryStream(
                        Frames(F(FrameKind.Hello, 0, Array.Empty<byte>()))),
                    new MemoryStream(),
                    _ => new FakeSession()));
            Assert.AreEqual(
                65,
                Program.Run(
                    new MemoryStream(),
                    new MemoryStream(),
                    _ => throw new InvalidOperationException("session failed")));
            Assert.AreEqual(
                65,
                Program.Run(
                    new MemoryStream(),
                    new MemoryStream(),
                    _ => throw new ArgumentException("session failed")));
        }

        [TestMethod]
        public void RunFromArgumentsUsesInjectedStreamsAndSessionFactory()
        {
            FakeSession session = new FakeSession();
            MemoryStream output = new MemoryStream();
            Assert.AreEqual(
                0,
                Program.RunFromArguments(
                    new[] { "--stdio" },
                    () => new MemoryStream(Frames(Shutdown())),
                    () => output,
                    _ => session));
            Assert.AreEqual(1, session.Probes);
            output.Position = 0;
            Assert.AreEqual(FrameKind.Ready, FrameProtocol.Read(output).Kind);

            using (IRecognitionSession created = Program.CreateSystemSession(new MemoryStream()))
            {
                Assert.IsInstanceOfType<RecognitionSession>(created);
            }
        }

        [TestMethod]
        public void RecognitionSessionAcceptsSameFinalInTwoAcknowledgedCyclesAndFencesStaleEngine()
        {
            MemoryStream output = new MemoryStream();
            FakeHostProbe probe = new FakeHostProbe();
            FakeRecognitionEngine first = new FakeRecognitionEngine
            {
                CompleteWithErrorOnCancel = true,
            };
            FakeRecognitionEngine second = new FakeRecognitionEngine();
            Queue<FakeRecognitionEngine> engines = new Queue<FakeRecognitionEngine>(
                new[] { first, second });
            using (RecognitionSession session = new RecognitionSession(
                output,
                probe,
                _ => engines.Dequeue()))
            {
                session.ProveReady();
                session.Start(10);
                first.EmitRecognized(" repeat ");
                first.EmitRecognized("duplicate");
                session.Stop(10);

                session.Start(11);
                first.EmitLateRecognized("stale old cycle");
                second.EmitRecognized("repeat");
                second.EmitCompleted(null);
                session.Stop(11);
            }

            Assert.AreEqual(1, probe.Probes);
            Assert.IsTrue(first.Cancelled);
            Assert.IsTrue(first.Disposed);
            Assert.IsTrue(second.Cancelled);
            output.Position = 0;
            HelperFrame firstFinal = FrameProtocol.Read(output);
            Assert.AreEqual(FrameKind.Final, firstFinal.Kind);
            Assert.AreEqual(10, firstFinal.RecognitionId);
            Assert.AreEqual("repeat", FrameProtocol.DecodeUtf8(firstFinal.Payload));
            HelperFrame secondFinal = FrameProtocol.Read(output);
            Assert.AreEqual(FrameKind.Final, secondFinal.Kind);
            Assert.AreEqual(11, secondFinal.RecognitionId);
            Assert.AreEqual("repeat", FrameProtocol.DecodeUtf8(secondFinal.Payload));
            Assert.AreEqual(output.Length, output.Position);
        }

        [TestMethod]
        public void RecognitionSessionStartFailureInvalidatesCycleAndAllowsRetry()
        {
            MemoryStream output = new MemoryStream();
            FakeRecognitionEngine failing = new FakeRecognitionEngine { ThrowOnStart = true };
            FakeRecognitionEngine succeeding = new FakeRecognitionEngine
            {
                ThrowOnCancel = true,
            };
            Queue<FakeRecognitionEngine> engines = new Queue<FakeRecognitionEngine>(
                new[] { failing, succeeding });
            using (RecognitionSession session = new RecognitionSession(
                output,
                new FakeHostProbe(),
                _ => engines.Dequeue()))
            {
                session.ProveReady();
                Assert.ThrowsExactly<InvalidOperationException>(() => session.Start(12));
                Assert.IsTrue(failing.Disposed);
                session.Start(13);
                succeeding.EmitCompleted(new InvalidOperationException("recognition failed"));
                session.Stop(13);
            }

            Assert.IsTrue(succeeding.Cancelled);
            Assert.IsTrue(succeeding.Disposed);
            output.Position = 0;
            HelperFrame error = FrameProtocol.Read(output);
            Assert.AreEqual(FrameKind.Error, error.Kind);
            Assert.AreEqual(13, error.RecognitionId);
            Assert.AreEqual(output.Length, output.Position);
        }

        [TestMethod]
        public void RecognitionCycleWriterBoundsTerminalAndPreventsPostStoppedOutput()
        {
            MemoryStream output = new MemoryStream();
            RecognitionCycleWriter writer = new RecognitionCycleWriter(output, new object());
            writer.Begin(30);
            writer.WriteRecognizedText(30, new string('x', FrameProtocol.MaxTextBytes + 1));
            writer.WriteRecognitionError(30);
            writer.Invalidate(30);
            writer.Barrier();
            FrameProtocol.Write(
                output,
                FrameKind.Stopped,
                30,
                Array.Empty<byte>());
            writer.WriteRecognizedText(30, "late");
            writer.WriteRecognitionError(30);

            output.Position = 0;
            HelperFrame error = FrameProtocol.Read(output);
            Assert.AreEqual(FrameKind.Error, error.Kind);
            Assert.AreEqual(30, error.RecognitionId);
            Assert.IsTrue(error.Payload.Length <= FrameProtocol.MaxControlBytes);
            HelperFrame stopped = FrameProtocol.Read(output);
            Assert.AreEqual(FrameKind.Stopped, stopped.Kind);
            Assert.AreEqual(30, stopped.RecognitionId);
            Assert.AreEqual(output.Length, output.Position);
        }

        [TestMethod]
        public void RecognitionCycleWriterClassifiesInvalidUnicodeAsError()
        {
            MemoryStream output = new MemoryStream();
            RecognitionCycleWriter writer = new RecognitionCycleWriter(output, new object());
            writer.Begin(31);
            writer.WriteRecognizedText(31, "\ud800");
            output.Position = 0;
            HelperFrame error = FrameProtocol.Read(output);
            Assert.AreEqual(FrameKind.Error, error.Kind);
            Assert.AreEqual(31, error.RecognitionId);
        }

        [TestMethod]
        [TestCategory("HostCapability")]
        public void RecognitionSessionStartsFeedsStopsOnInstalledEnUsRecognizer()
        {
            using (RecognitionSession session = new RecognitionSession(new MemoryStream()))
            {
                try
                {
                    session.ProveReady();
                }
                catch (HostCapabilityException exception)
                {
                    Assert.Inconclusive($"HostCapability:{exception.Failure}");
                }

                session.Start(1);
                session.Feed(1, new byte[FrameProtocol.MaxPcmBytes]);
                session.Stop(1);
                Assert.ThrowsExactly<InvalidDataException>(() => session.Stop(1));
            }
        }
    }
}
