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
                FrameProtocol.Write(stream, FrameKind.Pcm, payload);
                stream.Position = 0;
                HelperFrame frame = FrameProtocol.Read(stream);
                Assert.AreEqual(FrameKind.Pcm, frame.Kind);
                CollectionAssert.AreEqual(payload, frame.Payload);
            }
        }

        [TestMethod]
        public void OversizedPcmFailsBeforeWrite()
        {
            using (MemoryStream stream = new MemoryStream())
            {
                Assert.ThrowsException<InvalidDataException>(() =>
                    FrameProtocol.Write(
                        stream,
                        FrameKind.Pcm,
                        new byte[FrameProtocol.MaxPcmBytes + 1]));
                Assert.AreEqual(0, stream.Length);
            }
        }

        [TestMethod]
        public void InvalidMagicFailsClosed()
        {
            byte[] frame = new byte[FrameProtocol.HeaderBytes];
            frame[4] = 1;
            frame[5] = (byte)FrameKind.Stop;
            using (MemoryStream stream = new MemoryStream(frame))
            {
                Assert.ThrowsException<InvalidDataException>(() =>
                    FrameProtocol.Read(stream));
            }
        }

        [TestMethod]
        public void TruncatedPayloadFailsClosed()
        {
            using (MemoryStream stream = new MemoryStream())
            {
                FrameProtocol.Write(stream, FrameKind.Pcm, new byte[] { 1, 2 });
                stream.SetLength(stream.Length - 1);
                stream.Position = 0;
                Assert.ThrowsException<EndOfStreamException>(() =>
                    FrameProtocol.Read(stream));
            }
        }
    }
}
