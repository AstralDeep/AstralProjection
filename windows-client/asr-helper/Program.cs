using System;
using System.Globalization;
using System.IO;
using System.Speech.AudioFormat;
using System.Speech.Recognition;

namespace AstralSpeechHelper
{
    internal sealed class RecognitionSession : IDisposable
    {
        private readonly Stream output;
        private readonly object outputGate = new object();
        private SpeechRecognitionEngine? engine;
        private BoundedAudioStream? audio;
        private bool finalWritten;

        internal RecognitionSession(Stream output)
        {
            this.output = output;
        }

        internal void Start()
        {
            Stop();
            audio = new BoundedAudioStream();
            engine = new SpeechRecognitionEngine(new CultureInfo("en-US"));
            engine.LoadGrammar(new DictationGrammar());
            engine.SpeechRecognized += OnSpeechRecognized;
            engine.RecognizeCompleted += OnRecognizeCompleted;
            engine.SetInputToAudioStream(
                audio,
                new SpeechAudioFormatInfo(
                    48000,
                    AudioBitsPerSample.Sixteen,
                    AudioChannel.Mono));
            finalWritten = false;
            engine.RecognizeAsync(RecognizeMode.Multiple);
        }

        internal void Feed(byte[] pcm)
        {
            if (audio == null)
            {
                throw new InvalidDataException("PCM arrived before recognition start.");
            }

            audio.Write(pcm, 0, pcm.Length);
        }

        internal void Stop()
        {
            SpeechRecognitionEngine? currentEngine = engine;
            BoundedAudioStream? currentAudio = audio;
            engine = null;
            audio = null;
            currentAudio?.Complete();
            if (currentEngine != null)
            {
                currentEngine.RecognizeAsyncCancel();
                currentEngine.SpeechRecognized -= OnSpeechRecognized;
                currentEngine.RecognizeCompleted -= OnRecognizeCompleted;
                currentEngine.Dispose();
            }

            currentAudio?.Dispose();
        }

        public void Dispose()
        {
            Stop();
        }

        private void OnSpeechRecognized(object sender, SpeechRecognizedEventArgs args)
        {
            string text = (args.Result?.Text ?? string.Empty).Trim();
            if (finalWritten || text.Length == 0)
            {
                return;
            }

            byte[] payload = FrameProtocol.Utf8(text);
            if (payload.Length > FrameProtocol.MaxTextBytes)
            {
                WriteError();
                return;
            }

            finalWritten = true;
            lock (outputGate)
            {
                FrameProtocol.Write(output, FrameKind.Final, payload);
            }
        }

        private void OnRecognizeCompleted(object sender, RecognizeCompletedEventArgs args)
        {
            if (args.Error != null)
            {
                WriteError();
            }
        }

        private void WriteError()
        {
            lock (outputGate)
            {
                FrameProtocol.Write(
                    output,
                    FrameKind.Error,
                    FrameProtocol.Utf8("{\"reason\":\"local_recognition_failed\"}"));
            }
        }
    }

    internal static class Program
    {
        private const string StartPayload =
            "{\"locale\":\"en-US\",\"sample_rate\":48000,\"channels\":1}";

        internal static int Main(string[] args)
        {
            if (args.Length != 1 || !string.Equals(args[0], "--stdio", StringComparison.Ordinal))
            {
                return 64;
            }

            Stream input = Console.OpenStandardInput();
            Stream output = Console.OpenStandardOutput();
            using (RecognitionSession session = new RecognitionSession(output))
            {
                try
                {
                    FrameProtocol.Write(
                        output,
                        FrameKind.Ready,
                        FrameProtocol.Utf8("{\"locale\":\"en-US\"}"));
                    while (true)
                    {
                        HelperFrame frame = FrameProtocol.Read(input);
                        switch (frame.Kind)
                        {
                            case FrameKind.Start:
                                if (!string.Equals(
                                    FrameProtocol.DecodeUtf8(frame.Payload),
                                    StartPayload,
                                    StringComparison.Ordinal))
                                {
                                    return 65;
                                }

                                session.Start();
                                break;
                            case FrameKind.Pcm:
                                session.Feed(frame.Payload);
                                break;
                            case FrameKind.Stop:
                                if (frame.Payload.Length != 0)
                                {
                                    return 65;
                                }

                                session.Stop();
                                break;
                            case FrameKind.Shutdown:
                                if (frame.Payload.Length != 0)
                                {
                                    return 65;
                                }

                                return 0;
                            default:
                                return 65;
                        }
                    }
                }
                catch (EndOfStreamException)
                {
                    return 0;
                }
                catch (Exception exception) when (
                    exception is InvalidDataException
                    || exception is InvalidOperationException
                    || exception is ArgumentException)
                {
                    return 65;
                }
            }
        }
    }
}
