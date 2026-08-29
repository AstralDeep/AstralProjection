using System.IO;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace AstralSpeechHelper.Tests
{
    [TestClass]
    public sealed class BoundedAudioStreamTests
    {
        [TestMethod]
        public void PcmRemainsBoundedAndInMemory()
        {
            using (BoundedAudioStream stream = new BoundedAudioStream())
            {
                byte[] chunk = new byte[FrameProtocol.MaxPcmBytes];
                for (int index = 0; index < 8; index++)
                {
                    stream.Write(chunk, 0, chunk.Length);
                }

                Assert.AreEqual(BoundedAudioStream.CapacityBytes, stream.QueuedBytes);
                Assert.ThrowsException<InvalidDataException>(() =>
                    stream.Write(new byte[] { 1 }, 0, 1));
            }
        }

        [TestMethod]
        public void CompleteClearsQueuedAudio()
        {
            using (BoundedAudioStream stream = new BoundedAudioStream())
            {
                stream.Write(new byte[] { 1, 2 }, 0, 2);
                stream.Complete();
                Assert.AreEqual(0, stream.QueuedBytes);
                Assert.AreEqual(0, stream.Read(new byte[2], 0, 2));
            }
        }
    }
}
