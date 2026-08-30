using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;

namespace AstralSpeechHelper
{
    internal sealed class BoundedAudioStream : Stream
    {
        internal const int CapacityBytes = 256 * 1024;

        private readonly object gate = new object();
        private readonly Queue<byte[]> chunks = new Queue<byte[]>();
        private int queuedBytes;
        private int chunkOffset;
        private long readPosition;
        private bool completed;

        public override bool CanRead => true;

        public override bool CanSeek => false;

        public override bool CanWrite
        {
            get
            {
                lock (gate)
                {
                    return !completed;
                }
            }
        }

        // System.Speech wraps this stream as a COM IStream and snapshots Length
        // before recognition starts. The maximum value represents a live source;
        // Read still blocks until bounded PCM is available or Complete is called.
        public override long Length => long.MaxValue;

        public override long Position
        {
            get
            {
                lock (gate)
                {
                    return readPosition;
                }
            }
            set => throw new NotSupportedException();
        }

        internal int QueuedBytes
        {
            get
            {
                lock (gate)
                {
                    return queuedBytes;
                }
            }
        }

        public override void Write(byte[] buffer, int offset, int count)
        {
            ValidateBuffer(buffer, offset, count);
            if (count <= 0 || count > FrameProtocol.MaxPcmBytes)
            {
                throw new InvalidDataException("PCM chunk is empty or oversized.");
            }

            lock (gate)
            {
                if (completed || queuedBytes + count > CapacityBytes)
                {
                    throw new InvalidDataException("PCM buffer capacity exceeded.");
                }

                byte[] copy = new byte[count];
                Buffer.BlockCopy(buffer, offset, copy, 0, count);
                chunks.Enqueue(copy);
                queuedBytes += count;
                Monitor.PulseAll(gate);
            }
        }

        public override int Read(byte[] buffer, int offset, int count)
        {
            ValidateBuffer(buffer, offset, count);
            if (count == 0)
            {
                return 0;
            }

            lock (gate)
            {
                while (chunks.Count == 0 && !completed)
                {
                    Monitor.Wait(gate);
                }

                if (chunks.Count == 0)
                {
                    return 0;
                }

                byte[] chunk = chunks.Peek();
                int available = chunk.Length - chunkOffset;
                int copied = Math.Min(count, available);
                Buffer.BlockCopy(chunk, chunkOffset, buffer, offset, copied);
                chunkOffset += copied;
                queuedBytes -= copied;
                readPosition += copied;
                if (chunkOffset == chunk.Length)
                {
                    chunks.Dequeue();
                    chunkOffset = 0;
                }

                return copied;
            }
        }

        internal void Complete()
        {
            lock (gate)
            {
                completed = true;
                chunks.Clear();
                queuedBytes = 0;
                chunkOffset = 0;
                Monitor.PulseAll(gate);
            }
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                Complete();
            }

            base.Dispose(disposing);
        }

        public override void Flush()
        {
        }

        public override long Seek(long offset, SeekOrigin origin)
        {
            throw new NotSupportedException();
        }

        public override void SetLength(long value)
        {
            throw new NotSupportedException();
        }

        private static void ValidateBuffer(byte[] buffer, int offset, int count)
        {
            if (buffer == null)
            {
                throw new ArgumentNullException(nameof(buffer));
            }

            if (offset < 0 || count < 0 || offset > buffer.Length - count)
            {
                throw new ArgumentOutOfRangeException();
            }
        }
    }
}
