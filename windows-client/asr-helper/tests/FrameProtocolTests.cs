using System;
using System.IO;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace AstralSpeechHelper.Tests
{
    [TestClass]
    public sealed class FrameProtocolTests
    {
        [TestMethod]
        public void RoundTripPreservesBoundedPcm()
        {
            byte[] payload = new byte[] { 1, 2, 3, 4 };
            using (MemoryStream stream = new MemoryStream())
            {
                FrameProtocol.Write(stream, FrameKind.Pcm, 513, payload);
                stream.Position = 0;
                HelperFrame frame = FrameProtocol.Read(stream);
                Assert.AreEqual(FrameKind.Pcm, frame.Kind);
                Assert.AreEqual(513, frame.RecognitionId);
                CollectionAssert.AreEqual(payload, frame.Payload);
            }
        }

        [TestMethod]
        public void OversizedPcmFailsBeforeWrite()
        {
            using (MemoryStream stream = new MemoryStream())
            {
                Assert.ThrowsExactly<InvalidDataException>(() =>
                    FrameProtocol.Write(
                        stream,
                        FrameKind.Pcm,
                        1,
                        new byte[FrameProtocol.MaxPcmBytes + 1]));
                Assert.AreEqual(0, stream.Length);
            }
        }

        [TestMethod]
        public void InvalidMagicFailsClosed()
        {
            byte[] frame = new byte[FrameProtocol.HeaderBytes];
            frame[4] = FrameProtocol.Version;
            frame[5] = (byte)FrameKind.Stop;
            frame[6] = 1;
            using (MemoryStream stream = new MemoryStream(frame))
            {
                Assert.ThrowsExactly<InvalidDataException>(() =>
                    FrameProtocol.Read(stream));
            }
        }

        [TestMethod]
        public void TruncatedPayloadFailsClosed()
        {
            using (MemoryStream stream = new MemoryStream())
            {
                FrameProtocol.Write(stream, FrameKind.Pcm, 1, new byte[] { 1, 2 });
                stream.SetLength(stream.Length - 1);
                stream.Position = 0;
                Assert.ThrowsExactly<EndOfStreamException>(() =>
                    FrameProtocol.Read(stream));
            }
        }

        [TestMethod]
        public void CycleScopedKindsRequireNonzeroRecognitionId()
        {
            FrameKind[] cycleKinds = new[]
            {
                FrameKind.Start,
                FrameKind.Pcm,
                FrameKind.Stop,
                FrameKind.Final,
                FrameKind.Error,
                FrameKind.Stopped,
            };
            foreach (FrameKind kind in cycleKinds)
            {
                using (MemoryStream stream = new MemoryStream())
                {
                    Assert.ThrowsExactly<InvalidDataException>(() =>
                        FrameProtocol.Write(stream, kind, 0, Array.Empty<byte>()));
                }
            }
        }

        [TestMethod]
        public void ProcessScopedKindsRequireZeroRecognitionId()
        {
            FrameKind[] processKinds = new[]
            {
                FrameKind.Hello,
                FrameKind.Ready,
                FrameKind.Shutdown,
            };
            foreach (FrameKind kind in processKinds)
            {
                using (MemoryStream stream = new MemoryStream())
                {
                    Assert.ThrowsExactly<InvalidDataException>(() =>
                        FrameProtocol.Write(stream, kind, 1, Array.Empty<byte>()));
                }
            }
        }

        [TestMethod]
        public void UndefinedKindFailsBeforeWrite()
        {
            using (MemoryStream stream = new MemoryStream())
            {
                Assert.ThrowsExactly<InvalidDataException>(() =>
                    FrameProtocol.Write(
                        stream,
                        (FrameKind)byte.MaxValue,
                        0,
                        Array.Empty<byte>()));
                Assert.AreEqual(0, stream.Length);
            }
        }

        [TestMethod]
        public void VersionOneAndCycleMismatchFailClosedOnRead()
        {
            byte[] legacy = new byte[FrameProtocol.HeaderBytes];
            legacy[0] = (byte)'A';
            legacy[1] = (byte)'D';
            legacy[2] = (byte)'S';
            legacy[3] = (byte)'H';
            legacy[4] = 1;
            legacy[5] = (byte)FrameKind.Ready;
            using (MemoryStream stream = new MemoryStream(legacy))
            {
                Assert.ThrowsExactly<InvalidDataException>(() => FrameProtocol.Read(stream));
            }

            legacy[4] = FrameProtocol.Version;
            legacy[5] = (byte)FrameKind.Start;
            using (MemoryStream stream = new MemoryStream(legacy))
            {
                Assert.ThrowsExactly<InvalidDataException>(() => FrameProtocol.Read(stream));
            }
        }
    }
}
