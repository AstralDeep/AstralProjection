using System;
using System.Globalization;
using System.IO;
using System.Speech.AudioFormat;
using System.Speech.Recognition;

namespace AstralSpeechHelper
{
    internal interface IRecognitionSession : IDisposable
    {
        void Start();
        void Feed(byte[] pcm);
        void Stop();
    }

    internal sealed class RecognitionSession : IRecognitionSession
    {
        private readonly Stream output;
        private readonly object outputGate = new object();
        private SpeechRecognitionEngine? engine;
        private BoundedAudioStream? audio;
        private bool finalWritten;

        internal RecognitionSession(Stream output) { this.output = output; }

        public void Start()
        {
            if (engine != null || audio != null) throw new InvalidDataException("Recognition is already active.");
            audio = new BoundedAudioStream();
            engine = new SpeechRecognitionEngine(new CultureInfo("en-US"));
            engine.LoadGrammar(new DictationGrammar());
            engine.SpeechRecognized += OnSpeechRecognized;
            engine.RecognizeCompleted += OnRecognizeCompleted;
            engine.SetInputToAudioStream(audio, new SpeechAudioFormatInfo(48000, AudioBitsPerSample.Sixteen, AudioChannel.Mono));
            finalWritten = false;
            engine.RecognizeAsync(RecognizeMode.Multiple);
        }

        public void Feed(byte[] pcm)
        {
            if (audio == null) throw new InvalidDataException("PCM arrived before recognition start.");
            audio.Write(pcm, 0, pcm.Length);
        }

        public void Stop()
        {
            SpeechRecognitionEngine? currentEngine = engine;
            BoundedAudioStream? currentAudio = audio;
            if (currentEngine == null || currentAudio == null) throw new InvalidDataException("Recognition is not active.");
            engine = null;
            audio = null;
            currentAudio.Complete();
            currentEngine.RecognizeAsyncCancel();
            currentEngine.SpeechRecognized -= OnSpeechRecognized;
            currentEngine.RecognizeCompleted -= OnRecognizeCompleted;
            currentEngine.Dispose();
            currentAudio.Dispose();
        }

        public void Dispose()
        {
            if (engine != null && audio != null) Stop();
        }

        internal void WriteRecognizedText(string text)
        {
            string canonical = (text ?? string.Empty).Trim();
            if (finalWritten || canonical.Length == 0) return;
            byte[] payload = FrameProtocol.Utf8(canonical);
            if (payload.Length > FrameProtocol.MaxTextBytes) { WriteRecognitionError(); return; }
            finalWritten = true;
            lock (outputGate) FrameProtocol.Write(output, FrameKind.Final, payload);
        }

        internal void WriteRecognitionError()
        {
            lock (outputGate)
            {
                FrameProtocol.Write(output, FrameKind.Error, FrameProtocol.Utf8("{\"reason\":\"local_recognition_failed\"}"));
            }
        }

        private void OnSpeechRecognized(object sender, SpeechRecognizedEventArgs args) => WriteRecognizedText(args.Result?.Text ?? string.Empty);
        private void OnRecognizeCompleted(object sender, RecognizeCompletedEventArgs args)
        {
            if (args.Error != null) WriteRecognitionError();
        }
    }

    internal static class Program
    {
        internal const string StartPayload = "{\"locale\":\"en-US\",\"sample_rate\":48000,\"channels\":1}";

        internal static int Main(string[] args)
        {
            if (args.Length != 1 || !string.Equals(args[0], "--stdio", StringComparison.Ordinal)) return 64;
            return Run(Console.OpenStandardInput(), Console.OpenStandardOutput(), output => new RecognitionSession(output));
        }

        internal static int Run(Stream input, Stream output, Func<Stream, IRecognitionSession> sessionFactory)
        {
            bool active = false;
            using (IRecognitionSession session = sessionFactory(output))
            {
                try
                {
                    FrameProtocol.Write(output, FrameKind.Ready, FrameProtocol.Utf8("{\"locale\":\"en-US\"}"));
                    while (true)
                    {
                        HelperFrame frame = FrameProtocol.Read(input);
                        if (frame.Kind == FrameKind.Start)
                        {
                            if (active || !string.Equals(FrameProtocol.DecodeUtf8(frame.Payload), StartPayload, StringComparison.Ordinal)) return 65;
                            session.Start(); active = true;
                        }
                        else if (frame.Kind == FrameKind.Pcm)
                        {
                            if (!active) return 65;
                            session.Feed(frame.Payload);
                        }
                        else if (frame.Kind == FrameKind.Stop)
                        {
                            if (!active || frame.Payload.Length != 0) return 65;
                            session.Stop(); active = false;
                        }
                        else if (frame.Kind == FrameKind.Shutdown)
                        {
                            if (frame.Payload.Length != 0) return 65;
                            if (active) session.Stop();
                            return 0;
                        }
                        else return 65;
                    }
                }
                catch (EndOfStreamException) { return 65; }
                catch (Exception exception) when (exception is InvalidDataException || exception is InvalidOperationException || exception is ArgumentException) { return 65; }
            }
        }
    }
}
