using System;
using System.IO;
using System.Text;

namespace AstralSpeechHelper
{
    internal enum FrameKind : byte
    {
        Hello = 1,
        Ready = 2,
        Start = 3,
        Pcm = 4,
        Stop = 5,
        Final = 6,
        Error = 7,
        Shutdown = 8,
    }

    internal sealed class HelperFrame
    {
        internal HelperFrame(FrameKind kind, byte[] payload)
        {
            Kind = kind;
            Payload = payload;
        }

        internal FrameKind Kind { get; }

        internal byte[] Payload { get; }
    }

    internal static class FrameProtocol
    {
        internal const int HeaderBytes = 12;
        internal const int MaxPcmBytes = 32 * 1024;
        internal const int MaxTextBytes = 64 * 1024;
        internal const int MaxControlBytes = 4 * 1024;

        private static readonly byte[] Magic = Encoding.ASCII.GetBytes("ADSH");

        internal static HelperFrame Read(Stream input)
        {
            if (input == null)
            {
                throw new ArgumentNullException(nameof(input));
            }

            byte[] header = ReadExact(input, HeaderBytes);
            if (header[0] != Magic[0] || header[1] != Magic[1]
                || header[2] != Magic[2] || header[3] != Magic[3])
            {
                throw new InvalidDataException("Invalid helper frame magic.");
            }

            if (header[4] != 1 || header[6] != 0 || header[7] != 0
                || !Enum.IsDefined(typeof(FrameKind), header[5]))
            {
                throw new InvalidDataException("Invalid helper frame header.");
            }

            FrameKind kind = (FrameKind)header[5];
            uint rawLength = (uint)(header[8]
                | (header[9] << 8)
                | (header[10] << 16)
                | (header[11] << 24));
            int limit = Limit(kind);
            if (rawLength > limit)
            {
                throw new InvalidDataException("Helper frame exceeds its bound.");
            }

            return new HelperFrame(kind, ReadExact(input, checked((int)rawLength)));
        }

        internal static void Write(Stream output, FrameKind kind, byte[] payload)
        {
            if (output == null)
            {
                throw new ArgumentNullException(nameof(output));
            }

            if (payload == null)
            {
                throw new ArgumentNullException(nameof(payload));
            }

            if (payload.Length > Limit(kind))
            {
                throw new InvalidDataException("Helper frame exceeds its bound.");
            }

            byte[] header = new byte[HeaderBytes];
            Buffer.BlockCopy(Magic, 0, header, 0, Magic.Length);
            header[4] = 1;
            header[5] = (byte)kind;
            uint length = (uint)payload.Length;
            header[8] = (byte)(length & 0xff);
            header[9] = (byte)((length >> 8) & 0xff);
            header[10] = (byte)((length >> 16) & 0xff);
            header[11] = (byte)((length >> 24) & 0xff);
            output.Write(header, 0, header.Length);
            output.Write(payload, 0, payload.Length);
            output.Flush();
        }

        internal static byte[] Utf8(string value)
        {
            return new UTF8Encoding(false, true).GetBytes(value);
        }

        internal static string DecodeUtf8(byte[] value)
        {
            return new UTF8Encoding(false, true).GetString(value);
        }

        private static int Limit(FrameKind kind)
        {
            if (kind == FrameKind.Pcm)
            {
                return MaxPcmBytes;
            }

            if (kind == FrameKind.Final)
            {
                return MaxTextBytes;
            }

            return MaxControlBytes;
        }

        private static byte[] ReadExact(Stream input, int length)
        {
            byte[] value = new byte[length];
            int offset = 0;
            while (offset < length)
            {
                int read = input.Read(value, offset, length - offset);
                if (read <= 0)
                {
                    throw new EndOfStreamException("Truncated helper frame.");
                }

                offset += read;
            }

            return value;
        }
    }
}
