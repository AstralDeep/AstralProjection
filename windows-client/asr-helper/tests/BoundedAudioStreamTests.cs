using System;
using System.IO;
using System.Threading.Tasks;
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
                Assert.ThrowsExactly<InvalidDataException>(() =>
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

        [TestMethod]
        public void LiveStreamReportsMonotonicReadPositionWithoutSeeking()
        {
            using (BoundedAudioStream stream = new BoundedAudioStream())
            {
                Assert.AreEqual(long.MaxValue, stream.Length);
                Assert.AreEqual(0L, stream.Position);
                Assert.IsFalse(stream.CanSeek);

                stream.Write(new byte[] { 1, 2 }, 0, 2);
                byte[] output = new byte[1];
                Assert.AreEqual(1, stream.Read(output, 0, output.Length));
                Assert.AreEqual(1L, stream.Position);
                CollectionAssert.AreEqual(new byte[] { 1 }, output);
                Assert.ThrowsExactly<NotSupportedException>(() => stream.Position = 0);
            }
        }

        [TestMethod]
        public void CompleteDisablesWritesBeforeAllocatingMorePcm()
        {
            using (BoundedAudioStream stream = new BoundedAudioStream())
            {
                stream.Complete();
                Assert.IsFalse(stream.CanWrite);
                Assert.ThrowsExactly<InvalidDataException>(() =>
                    stream.Write(new byte[] { 1 }, 0, 1));
            }
        }

        [TestMethod]
        public void ZeroLengthReadReturnsWithoutWaitingForPcm()
        {
            using (BoundedAudioStream stream = new BoundedAudioStream())
            {
                Task<int> read = Task.Run(() => stream.Read(Array.Empty<byte>(), 0, 0));
                Assert.IsTrue(read.Wait(TimeSpan.FromSeconds(1)));
                Assert.AreEqual(0, read.Result);
            }
        }
    }
}
