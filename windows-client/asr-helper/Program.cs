using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Speech.AudioFormat;
using System.Speech.Recognition;

namespace AstralSpeechHelper
{
    internal enum HostCapabilityFailure
    {
        ExactLocaleUnavailable,
        RequiredAudioFormatUnavailable,
        RecognizerConstructionFailed,
    }

    internal sealed class HostCapabilityException : Exception
    {
        internal HostCapabilityException(
            HostCapabilityFailure failure,
            string message,
            Exception? innerException = null)
            : base(message, innerException)
        {
            Failure = failure;
        }

        internal HostCapabilityFailure Failure { get; }
    }

    internal sealed class RecognitionAudioFormat
    {
        internal RecognitionAudioFormat(int samplesPerSecond, int bitsPerSample, int channelCount)
        {
            SamplesPerSecond = samplesPerSecond;
            BitsPerSample = bitsPerSample;
            ChannelCount = channelCount;
        }

        internal int SamplesPerSecond { get; }

        internal int BitsPerSample { get; }

        internal int ChannelCount { get; }

        internal bool IsRequiredFormat => SamplesPerSecond == 16000
            && BitsPerSample == 16
            && ChannelCount == 1;
    }

    internal sealed class RecognizerCapability
    {
        internal RecognizerCapability(
            string id,
            string cultureName,
            IEnumerable<RecognitionAudioFormat> audioFormats)
        {
            Id = id ?? throw new ArgumentNullException(nameof(id));
            CultureName = cultureName ?? throw new ArgumentNullException(nameof(cultureName));
            AudioFormats = new List<RecognitionAudioFormat>(
                audioFormats ?? throw new ArgumentNullException(nameof(audioFormats)));
        }

        internal string Id { get; }

        internal string CultureName { get; }

        internal IReadOnlyList<RecognitionAudioFormat> AudioFormats { get; }

        internal bool SupportsRequiredFormat
        {
            get
            {
                foreach (RecognitionAudioFormat format in AudioFormats)
                {
                    if (format.IsRequiredFormat)
                    {
                        return true;
                    }
                }

                return false;
            }
        }
    }

    internal static class RecognitionCapabilitySelector
    {
        internal static RecognizerCapability SelectRequired(
            IEnumerable<RecognizerCapability> capabilities)
        {
            if (capabilities == null)
            {
                throw new ArgumentNullException(nameof(capabilities));
            }

            bool exactLocaleFound = false;
            RecognizerCapability? selected = null;
            foreach (RecognizerCapability capability in capabilities)
            {
                if (!string.Equals(capability.CultureName, "en-US", StringComparison.Ordinal))
                {
                    continue;
                }

                exactLocaleFound = true;
                if (!capability.SupportsRequiredFormat)
                {
                    continue;
                }

                if (selected == null
                    || string.CompareOrdinal(capability.Id, selected.Id) < 0)
                {
                    selected = capability;
                }
            }

            if (!exactLocaleFound)
            {
                throw new HostCapabilityException(
                    HostCapabilityFailure.ExactLocaleUnavailable,
                    "No exact en-US speech recognizer is installed.");
            }

            if (selected == null)
            {
                throw new HostCapabilityException(
                    HostCapabilityFailure.RequiredAudioFormatUnavailable,
                    "No exact en-US recognizer supports 16-kHz 16-bit mono PCM.");
            }

            return selected;
        }
    }

    internal interface IRecognitionHostProbe
    {
        string ProveReady();
    }

    internal sealed class SystemRecognitionHostProbe : IRecognitionHostProbe
    {
        private readonly Func<IEnumerable<RecognizerCapability>> loadCapabilities;
        private readonly Action<string> validateRecognizerConstruction;

        internal SystemRecognitionHostProbe()
            : this(LoadCapabilities, ValidateRecognizerConstruction)
        {
        }

        internal SystemRecognitionHostProbe(
            Func<IEnumerable<RecognizerCapability>> loadCapabilities,
            Action<string> validateRecognizerConstruction)
        {
            this.loadCapabilities = loadCapabilities
                ?? throw new ArgumentNullException(nameof(loadCapabilities));
            this.validateRecognizerConstruction = validateRecognizerConstruction
                ?? throw new ArgumentNullException(nameof(validateRecognizerConstruction));
        }

        public string ProveReady()
        {
            RecognizerCapability selected = RecognitionCapabilitySelector.SelectRequired(
                loadCapabilities());
            try
            {
                validateRecognizerConstruction(selected.Id);
            }
            catch (HostCapabilityException)
            {
                throw;
            }
            catch (Exception exception)
            {
                throw new HostCapabilityException(
                    HostCapabilityFailure.RecognizerConstructionFailed,
                    "The selected en-US recognizer could not be constructed.",
                    exception);
            }

            return selected.Id;
        }

        private static IEnumerable<RecognizerCapability> LoadCapabilities()
        {
            List<RecognizerCapability> capabilities = new List<RecognizerCapability>();
            foreach (RecognizerInfo recognizer in SpeechRecognitionEngine.InstalledRecognizers())
            {
                List<RecognitionAudioFormat> formats = new List<RecognitionAudioFormat>();
                foreach (SpeechAudioFormatInfo format in recognizer.SupportedAudioFormats)
                {
                    formats.Add(
                        new RecognitionAudioFormat(
                            format.SamplesPerSecond,
                            format.BitsPerSample,
                            format.ChannelCount));
                }

                capabilities.Add(
                    new RecognizerCapability(
                        recognizer.Id,
                        recognizer.Culture.Name,
                        formats));
            }

            return capabilities;
        }

        private static void ValidateRecognizerConstruction(string recognizerId)
        {
            using (IRecognitionEngine engine = new SystemRecognitionEngine(recognizerId))
            {
            }
        }
    }

    internal delegate void RecognitionTextHandler(IRecognitionEngine sender, string text);

    internal delegate void RecognitionCompletedHandler(
        IRecognitionEngine sender,
        Exception? error);

    internal interface IRecognitionEngine : IDisposable
    {
        event RecognitionTextHandler? Recognized;

        event RecognitionCompletedHandler? Completed;

        void SetInput(BoundedAudioStream audio);

        void Start();

        void Cancel();
    }

    internal sealed class SystemRecognitionEngine : IRecognitionEngine
    {
        private readonly Action<BoundedAudioStream> setInput;
        private readonly Action start;
        private readonly Action cancel;
        private readonly Action dispose;

        internal SystemRecognitionEngine(string recognizerId)
        {
            SpeechRecognitionEngine nextEngine = new SpeechRecognitionEngine(recognizerId);
            try
            {
                nextEngine.LoadGrammar(new DictationGrammar());
                nextEngine.SpeechRecognized += OnSpeechRecognized;
                nextEngine.RecognizeCompleted += OnRecognizeCompleted;
            }
            catch
            {
                nextEngine.Dispose();
                throw;
            }

            setInput = audio => nextEngine.SetInputToAudioStream(
                audio,
                new SpeechAudioFormatInfo(
                    16000,
                    AudioBitsPerSample.Sixteen,
                    AudioChannel.Mono));
            start = () => nextEngine.RecognizeAsync(RecognizeMode.Multiple);
            cancel = nextEngine.RecognizeAsyncCancel;
            dispose = () =>
            {
                nextEngine.SpeechRecognized -= OnSpeechRecognized;
                nextEngine.RecognizeCompleted -= OnRecognizeCompleted;
                nextEngine.Dispose();
            };
        }

        internal SystemRecognitionEngine(
            Action<BoundedAudioStream> setInput,
            Action start,
            Action cancel,
            Action dispose)
        {
            this.setInput = setInput ?? throw new ArgumentNullException(nameof(setInput));
            this.start = start ?? throw new ArgumentNullException(nameof(start));
            this.cancel = cancel ?? throw new ArgumentNullException(nameof(cancel));
            this.dispose = dispose ?? throw new ArgumentNullException(nameof(dispose));
        }

        public event RecognitionTextHandler? Recognized;

        public event RecognitionCompletedHandler? Completed;

        public void SetInput(BoundedAudioStream audio) => setInput(audio);

        public void Start() => start();

        public void Cancel() => cancel();

        public void Dispose() => dispose();

        private void OnSpeechRecognized(object sender, SpeechRecognizedEventArgs args)
        {
            Recognized?.Invoke(this, args.Result?.Text ?? string.Empty);
        }

        private void OnRecognizeCompleted(object sender, RecognizeCompletedEventArgs args)
        {
            Completed?.Invoke(this, args.Error);
        }
    }

    internal sealed class RecognitionCycleWriter
    {
        private const string FailurePayload = "{\"reason\":\"local_recognition_failed\"}";

        private readonly Stream output;
        private readonly object outputGate;
        private ushort activeRecognitionId;
        private bool terminalWritten;

        internal RecognitionCycleWriter(Stream output, object outputGate)
        {
            this.output = output ?? throw new ArgumentNullException(nameof(output));
            this.outputGate = outputGate ?? throw new ArgumentNullException(nameof(outputGate));
        }

        internal ushort ActiveRecognitionId
        {
            get
            {
                lock (outputGate)
                {
                    return activeRecognitionId;
                }
            }
        }

        internal void Begin(ushort recognitionId)
        {
            if (recognitionId == 0)
            {
                throw new InvalidDataException("Recognition cycle zero is reserved.");
            }

            lock (outputGate)
            {
                if (activeRecognitionId != 0)
                {
                    throw new InvalidDataException("Recognition is already active.");
                }

                activeRecognitionId = recognitionId;
                terminalWritten = false;
            }
        }

        internal void Invalidate(ushort recognitionId)
        {
            lock (outputGate)
            {
                if (recognitionId == 0 || recognitionId != activeRecognitionId)
                {
                    throw new InvalidDataException("Recognition cycle is not active.");
                }

                activeRecognitionId = 0;
                terminalWritten = true;
            }
        }

        internal void WriteRecognizedText(ushort recognitionId, string text)
        {
            string canonical = (text ?? string.Empty).Trim();
            if (canonical.Length == 0)
            {
                return;
            }

            byte[] payload;
            try
            {
                payload = FrameProtocol.Utf8(canonical);
            }
            catch (ArgumentException)
            {
                WriteRecognitionError(recognitionId);
                return;
            }

            lock (outputGate)
            {
                if (recognitionId == 0
                    || recognitionId != activeRecognitionId
                    || terminalWritten)
                {
                    return;
                }

                terminalWritten = true;
                if (payload.Length > FrameProtocol.MaxTextBytes)
                {
                    FrameProtocol.Write(
                        output,
                        FrameKind.Error,
                        recognitionId,
                        FrameProtocol.Utf8(FailurePayload));
                    return;
                }

                FrameProtocol.Write(output, FrameKind.Final, recognitionId, payload);
            }
        }

        internal void WriteRecognitionError(ushort recognitionId)
        {
            lock (outputGate)
            {
                if (recognitionId == 0
                    || recognitionId != activeRecognitionId
                    || terminalWritten)
                {
                    return;
                }

                terminalWritten = true;
                FrameProtocol.Write(
                    output,
                    FrameKind.Error,
                    recognitionId,
                    FrameProtocol.Utf8(FailurePayload));
            }
        }

        internal void Barrier()
        {
            lock (outputGate)
            {
            }
        }
    }

    internal interface IRecognitionSession : IDisposable
    {
        void ProveReady();

        void Start(ushort recognitionId);

        void Feed(ushort recognitionId, byte[] pcm);

        void Stop(ushort recognitionId);
    }

    internal sealed class RecognitionSession : IRecognitionSession
    {
        private readonly object outputGate = new object();
        private readonly IRecognitionHostProbe hostProbe;
        private readonly Func<string, IRecognitionEngine> engineFactory;
        private readonly RecognitionCycleWriter cycleWriter;
        private string? recognizerId;
        private IRecognitionEngine? engine;
        private BoundedAudioStream? audio;

        internal RecognitionSession(Stream output)
            : this(
                output,
                new SystemRecognitionHostProbe(),
                CreateSystemEngine)
        {
        }

        internal static IRecognitionEngine CreateSystemEngine(string recognizerId)
        {
            return new SystemRecognitionEngine(recognizerId);
        }

        internal RecognitionSession(
            Stream output,
            IRecognitionHostProbe hostProbe,
            Func<string, IRecognitionEngine> engineFactory)
        {
            this.hostProbe = hostProbe ?? throw new ArgumentNullException(nameof(hostProbe));
            this.engineFactory = engineFactory ?? throw new ArgumentNullException(nameof(engineFactory));
            cycleWriter = new RecognitionCycleWriter(output, outputGate);
        }

        public void ProveReady()
        {
            lock (outputGate)
            {
                if (recognizerId != null || engine != null || audio != null)
                {
                    throw new InvalidDataException("Recognition host was already probed.");
                }
            }

            string selectedRecognizerId = hostProbe.ProveReady();
            if (string.IsNullOrWhiteSpace(selectedRecognizerId))
            {
                throw new HostCapabilityException(
                    HostCapabilityFailure.RecognizerConstructionFailed,
                    "The selected recognizer identifier is empty.");
            }

            lock (outputGate)
            {
                recognizerId = selectedRecognizerId;
            }
        }

        public void Start(ushort recognitionId)
        {
            string selectedRecognizerId;
            lock (outputGate)
            {
                if (recognitionId == 0)
                {
                    throw new InvalidDataException("Recognition cycle zero is reserved.");
                }

                if (recognizerId == null)
                {
                    throw new InvalidDataException("Recognition host is not ready.");
                }

                if (engine != null || audio != null || cycleWriter.ActiveRecognitionId != 0)
                {
                    throw new InvalidDataException("Recognition is already active.");
                }

                selectedRecognizerId = recognizerId;
            }

            BoundedAudioStream nextAudio = new BoundedAudioStream();
            IRecognitionEngine? nextEngine = null;
            bool published = false;
            try
            {
                nextEngine = engineFactory(selectedRecognizerId);
                nextEngine.Recognized += OnRecognized;
                nextEngine.Completed += OnCompleted;
                nextEngine.SetInput(nextAudio);
                lock (outputGate)
                {
                    engine = nextEngine;
                    audio = nextAudio;
                    cycleWriter.Begin(recognitionId);
                    published = true;
                }

                nextEngine.Start();
            }
            catch
            {
                if (published)
                {
                    lock (outputGate)
                    {
                        engine = null;
                        audio = null;
                        cycleWriter.Invalidate(recognitionId);
                    }
                }

                try
                {
                    if (nextEngine != null)
                    {
                        nextEngine.Recognized -= OnRecognized;
                        nextEngine.Completed -= OnCompleted;
                        try
                        {
                            nextEngine.Dispose();
                        }
                        finally
                        {
                            nextAudio.Dispose();
                        }
                    }
                    else
                    {
                        nextAudio.Dispose();
                    }
                }
                finally
                {
                    cycleWriter.Barrier();
                }

                throw;
            }
        }

        public void Feed(ushort recognitionId, byte[] pcm)
        {
            BoundedAudioStream currentAudio;
            lock (outputGate)
            {
                if (recognitionId == 0
                    || recognitionId != cycleWriter.ActiveRecognitionId
                    || audio == null)
                {
                    throw new InvalidDataException("PCM cycle is not active.");
                }

                currentAudio = audio;
            }

            currentAudio.Write(pcm, 0, pcm.Length);
        }

        public void Stop(ushort recognitionId)
        {
            IRecognitionEngine currentEngine;
            BoundedAudioStream currentAudio;
            lock (outputGate)
            {
                if (recognitionId == 0
                    || recognitionId != cycleWriter.ActiveRecognitionId
                    || engine == null
                    || audio == null)
                {
                    throw new InvalidDataException("Recognition cycle is not active.");
                }

                currentEngine = engine;
                currentAudio = audio;
                engine = null;
                audio = null;
                cycleWriter.Invalidate(recognitionId);
            }

            try
            {
                currentAudio.Complete();
                try
                {
                    currentEngine.Cancel();
                }
                catch (InvalidOperationException)
                {
                    // Recognition may have completed between its terminal callback and stop.
                }
            }
            finally
            {
                currentEngine.Recognized -= OnRecognized;
                currentEngine.Completed -= OnCompleted;
                try
                {
                    currentEngine.Dispose();
                }
                finally
                {
                    currentAudio.Dispose();
                    cycleWriter.Barrier();
                }
            }
        }

        public void Dispose()
        {
            ushort activeRecognitionId = cycleWriter.ActiveRecognitionId;
            if (activeRecognitionId != 0)
            {
                Stop(activeRecognitionId);
            }
        }

        private void OnRecognized(IRecognitionEngine sender, string text)
        {
            ushort recognitionId = RecognitionIdFor(sender);
            if (recognitionId != 0)
            {
                cycleWriter.WriteRecognizedText(recognitionId, text);
            }
        }

        private void OnCompleted(IRecognitionEngine sender, Exception? error)
        {
            if (error == null)
            {
                return;
            }

            ushort recognitionId = RecognitionIdFor(sender);
            if (recognitionId != 0)
            {
                cycleWriter.WriteRecognitionError(recognitionId);
            }
        }

        private ushort RecognitionIdFor(IRecognitionEngine sender)
        {
            lock (outputGate)
            {
                return ReferenceEquals(sender, engine)
                    ? cycleWriter.ActiveRecognitionId
                    : (ushort)0;
            }
        }
    }

    internal static class Program
    {
        internal const int HostCapabilityExitCode = 69;
        internal const string StartPayload = "{\"locale\":\"en-US\",\"sample_rate\":16000,\"channels\":1}";
        internal const string ReadyPayload = "{\"locale\":\"en-US\"}";

        internal static int Main(string[] args)
        {
            return RunFromArguments(
                args,
                Console.OpenStandardInput,
                Console.OpenStandardOutput,
                CreateSystemSession);
        }

        internal static int RunFromArguments(
            string[] args,
            Func<Stream> inputFactory,
            Func<Stream> outputFactory,
            Func<Stream, IRecognitionSession> sessionFactory)
        {
            if (args.Length != 1 || !string.Equals(args[0], "--stdio", StringComparison.Ordinal))
            {
                return 64;
            }

            return Run(
                inputFactory(),
                outputFactory(),
                sessionFactory);
        }

        internal static IRecognitionSession CreateSystemSession(Stream output)
        {
            return new RecognitionSession(output);
        }

        internal static int Run(
            Stream input,
            Stream output,
            Func<Stream, IRecognitionSession> sessionFactory)
        {
            ushort activeRecognitionId = 0;
            try
            {
                using (IRecognitionSession session = sessionFactory(output))
                {
                    session.ProveReady();
                    FrameProtocol.Write(
                        output,
                        FrameKind.Ready,
                        0,
                        FrameProtocol.Utf8(ReadyPayload));
                    while (true)
                    {
                        HelperFrame frame = FrameProtocol.Read(input);
                        if (frame.Kind == FrameKind.Start)
                        {
                            if (activeRecognitionId != 0
                                || !string.Equals(
                                    FrameProtocol.DecodeUtf8(frame.Payload),
                                    StartPayload,
                                    StringComparison.Ordinal))
                            {
                                return 65;
                            }

                            session.Start(frame.RecognitionId);
                            activeRecognitionId = frame.RecognitionId;
                        }
                        else if (frame.Kind == FrameKind.Pcm)
                        {
                            if (frame.RecognitionId != activeRecognitionId
                                || frame.Payload.Length == 0)
                            {
                                return 65;
                            }

                            session.Feed(frame.RecognitionId, frame.Payload);
                        }
                        else if (frame.Kind == FrameKind.Stop)
                        {
                            if (frame.RecognitionId != activeRecognitionId
                                || frame.Payload.Length != 0)
                            {
                                return 65;
                            }

                            session.Stop(frame.RecognitionId);
                            activeRecognitionId = 0;
                            FrameProtocol.Write(
                                output,
                                FrameKind.Stopped,
                                frame.RecognitionId,
                                Array.Empty<byte>());
                        }
                        else if (frame.Kind == FrameKind.Shutdown)
                        {
                            if (frame.Payload.Length != 0)
                            {
                                return 65;
                            }

                            if (activeRecognitionId != 0)
                            {
                                session.Stop(activeRecognitionId);
                            }

                            return 0;
                        }
                        else
                        {
                            return 65;
                        }
                    }
                }
            }
            catch (HostCapabilityException)
            {
                return HostCapabilityExitCode;
            }
            catch (EndOfStreamException)
            {
                return 65;
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
