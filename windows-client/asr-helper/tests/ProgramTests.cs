using System;
using System.IO;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace AstralSpeechHelper.Tests
{
    [TestClass]
    public sealed class ProgramTests
    {
        private sealed class FakeSession : IRecognitionSession
        {
            internal int Starts { get; private set; }
            internal int Stops { get; private set; }
            internal int Disposals { get; private set; }
            public void Start() => Starts++;
            public void Feed(byte[] pcm) { }
            public void Stop() => Stops++;
            public void Dispose() => Disposals++;
        }

        private static byte[] Frames(params Tuple<FrameKind, byte[]>[] values)
        {
            using (MemoryStream stream = new MemoryStream())
            {
                foreach (Tuple<FrameKind, byte[]> value in values) FrameProtocol.Write(stream, value.Item1, value.Item2);
                return stream.ToArray();
            }
        }

        [TestMethod]
        public void MainRejectsInvalidProcessArguments()
        {
            Assert.AreEqual(64, Program.Main(Array.Empty<string>()));
        }

        [TestMethod]
        public void RunWritesReadyBeforeReading()
        {
            MemoryStream output = new MemoryStream();
            Assert.AreEqual(65, Program.Run(new MemoryStream(), output, _ => new FakeSession()));
            output.Position = 0;
            Assert.AreEqual(FrameKind.Ready, FrameProtocol.Read(output).Kind);
        }

        [TestMethod]
        public void RunRejectsStopBeforeStart()
        {
            Assert.AreEqual(65, Program.Run(new MemoryStream(Frames(Tuple.Create(FrameKind.Stop, Array.Empty<byte>()))), new MemoryStream(), _ => new FakeSession()));
        }

        [TestMethod]
        public void RunRejectsRepeatedStart()
        {
            byte[] start = FrameProtocol.Utf8(Program.StartPayload);
            Assert.AreEqual(65, Program.Run(new MemoryStream(Frames(Tuple.Create(FrameKind.Start, start), Tuple.Create(FrameKind.Start, start))), new MemoryStream(), _ => new FakeSession()));
        }

        [TestMethod]
        public void RunRejectsTruncatedActiveInput()
        {
            byte[] start = Frames(Tuple.Create(FrameKind.Start, FrameProtocol.Utf8(Program.StartPayload)));
            byte[] truncated = new byte[start.Length + 2];
            Buffer.BlockCopy(start, 0, truncated, 0, start.Length);
            truncated[start.Length] = (byte)'A';
            Assert.AreEqual(65, Program.Run(new MemoryStream(truncated), new MemoryStream(), _ => new FakeSession()));
        }

        [TestMethod]
        public void RunStopsAndShutsDownOnce()
        {
            FakeSession session = new FakeSession();
            byte[] input = Frames(Tuple.Create(FrameKind.Start, FrameProtocol.Utf8(Program.StartPayload)), Tuple.Create(FrameKind.Stop, Array.Empty<byte>()), Tuple.Create(FrameKind.Shutdown, Array.Empty<byte>()));
            Assert.AreEqual(0, Program.Run(new MemoryStream(input), new MemoryStream(), _ => session));
            Assert.AreEqual(1, session.Starts);
            Assert.AreEqual(1, session.Stops);
            Assert.AreEqual(1, session.Disposals);
        }

        [TestMethod]
        public void RunFeedsPcmAndStopsActiveSessionOnShutdown()
        {
            FakeSession session = new FakeSession();
            byte[] input = Frames(Tuple.Create(FrameKind.Start, FrameProtocol.Utf8(Program.StartPayload)), Tuple.Create(FrameKind.Pcm, new byte[] { 0, 0 }), Tuple.Create(FrameKind.Shutdown, Array.Empty<byte>()));
            Assert.AreEqual(0, Program.Run(new MemoryStream(input), new MemoryStream(), _ => session));
            Assert.AreEqual(1, session.Starts);
            Assert.AreEqual(1, session.Stops);
        }

        [TestMethod]
        public void RecognitionSessionDeduplicatesFinal()
        {
            MemoryStream output = new MemoryStream();
            using (RecognitionSession session = new RecognitionSession(output))
            {
                session.WriteRecognizedText(" result ");
                session.WriteRecognizedText("duplicate");
            }
            output.Position = 0;
            HelperFrame frame = FrameProtocol.Read(output);
            Assert.AreEqual(FrameKind.Final, frame.Kind);
            Assert.AreEqual("result", FrameProtocol.DecodeUtf8(frame.Payload));
            Assert.AreEqual(output.Length, output.Position);
        }

        [TestMethod]
        public void RecognitionSessionWritesBoundedError()
        {
            MemoryStream output = new MemoryStream();
            using (RecognitionSession session = new RecognitionSession(output)) session.WriteRecognitionError();
            output.Position = 0;
            HelperFrame frame = FrameProtocol.Read(output);
            Assert.AreEqual(FrameKind.Error, frame.Kind);
            Assert.IsTrue(frame.Payload.Length <= FrameProtocol.MaxControlBytes);
        }

        [TestMethod]
        public void RecognitionSessionStartsFeedsStops()
        {
            using (RecognitionSession session = new RecognitionSession(new MemoryStream()))
            {
                session.Start();
                session.Feed(new byte[FrameProtocol.MaxPcmBytes]);
                session.Stop();
                Assert.ThrowsException<InvalidDataException>(() => session.Stop());
            }
        }

        [TestMethod]
        public void RecognitionSessionRejectsEmptyAndOversizedFinals()
        {
            MemoryStream output = new MemoryStream();
            using (RecognitionSession session = new RecognitionSession(output))
            {
                session.WriteRecognizedText("   ");
                Assert.AreEqual(0, output.Length);
                session.WriteRecognizedText(new string('x', FrameProtocol.MaxTextBytes + 1));
            }
            output.Position = 0;
            Assert.AreEqual(FrameKind.Error, FrameProtocol.Read(output).Kind);
        }
    }
}
