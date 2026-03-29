const chatContainer = document.getElementById('chatContainer');
const chatMirror = document.getElementById('chatMirror');
const micBtn = document.getElementById('micBtn');
const micLangLabel = document.getElementById('micLangLabel');
const statusEl = document.getElementById('status');
const interimText = document.getElementById('interimText');
const textInput = document.getElementById('textInput');
const sendBtn = document.getElementById('sendBtn');

let isListening = false;
let isMirrorListening = false;
let isProcessing = false;
let recognition = null;
let mirrorRecognition = null;
let conversationContext = [];
let micLang = 'ko';
let finalTranscript = '';
let mirrorFinalTranscript = '';
let silenceTimer = null;
let mirrorSilenceTimer = null;
let ttsJaEnabled = false;
let ttsKoEnabled = false;

// ===== localStorage persistence =====
function saveSettings() {
    const settings = {
        ttsJaEnabled,
        ttsKoEnabled,
        voiceJa: document.getElementById('voiceJa').value,
        voiceKo: document.getElementById('voiceKo').value,
        fontSize: document.getElementById('fontSizeSetting').value,
        silenceTimeout: document.getElementById('silenceTimeout').value,
        sttMode: document.getElementById('sttMode').value,
        micLang,
    };
    localStorage.setItem('interpreterSettings', JSON.stringify(settings));
}

function loadSettings() {
    try {
        const raw = localStorage.getItem('interpreterSettings');
        if (!raw) return;
        const s = JSON.parse(raw);

        if (s.ttsJaEnabled !== undefined) {
            ttsJaEnabled = s.ttsJaEnabled;
            document.querySelector('#ttsJaToggle .toggle-dot').classList.toggle('on', ttsJaEnabled);
        }
        if (s.ttsKoEnabled !== undefined) {
            ttsKoEnabled = s.ttsKoEnabled;
            document.querySelector('#ttsKoToggle .toggle-dot').classList.toggle('on', ttsKoEnabled);
        }
        if (s.voiceJa) document.getElementById('voiceJa').value = s.voiceJa;
        if (s.voiceKo) document.getElementById('voiceKo').value = s.voiceKo;
        if (s.fontSize) {
            document.getElementById('fontSizeSetting').value = s.fontSize;
            document.documentElement.style.fontSize = s.fontSize + 'px';
        }
        if (s.silenceTimeout) document.getElementById('silenceTimeout').value = s.silenceTimeout;
        if (s.sttMode) {
            const mode = s.sttMode === 'browser' ? 'normal' : s.sttMode;
            document.getElementById('sttMode').value = mode;
        }
        if (s.micLang) {
            micLang = s.micLang;
            micLangLabel.textContent = micLang === 'ko' ? 'KO' : 'JA';
            document.getElementById('micLangBtn').classList.toggle('ja-mode', micLang === 'ja');
        }
    } catch (e) {
        // ignore corrupt settings
    }
}

// ===== Language detection =====
function detectLang(text) {
    let ko = 0, ja = 0;
    for (const ch of text) {
        const code = ch.charCodeAt(0);
        if ((code >= 0xAC00 && code <= 0xD7AF) || (code >= 0x1100 && code <= 0x11FF) || (code >= 0x3130 && code <= 0x318F)) {
            ko++;
        }
        if ((code >= 0x3040 && code <= 0x309F) || (code >= 0x30A0 && code <= 0x30FF)) {
            ja++;
        }
        if (code >= 0x4E00 && code <= 0x9FFF) {
            ja += 0.3;
        }
    }
    if (ko === 0 && ja === 0) return 'ko';
    return ko >= ja ? 'ko' : 'ja';
}

// ===== Speech Recognition =====
const SpeechRecognition = window.SpeechRecognition || window.webkitSpeechRecognition;
if (!SpeechRecognition) {
    showError('이 브라우저는 음성 인식을 지원하지 않습니다. Chrome을 사용해주세요.');
}

function getSilenceTimeout() {
    return document.getElementById('silenceTimeout').value;
}

function initRecognition() {
    if (!SpeechRecognition) return null;

    const rec = new SpeechRecognition();
    rec.lang = micLang === 'ko' ? 'ko-KR' : 'ja-JP';
    const isAuto = getSilenceTimeout() === 'auto';
    rec.continuous = !isAuto;
    rec.interimResults = true;
    rec.maxAlternatives = 1;

    rec.onresult = (event) => {
        let interim = '';
        for (let i = event.resultIndex; i < event.results.length; i++) {
            const transcript = event.results[i][0].transcript;
            if (event.results[i].isFinal) {
                finalTranscript += transcript;
            } else {
                interim += transcript;
            }
        }
        interimText.textContent = finalTranscript + interim;
        resetSilenceTimer();
    };

    rec.onend = () => {
        setListening(false);
        interimText.textContent = '';
        if (finalTranscript.trim()) {
            handleSpeechResult(finalTranscript.trim());
        }
        finalTranscript = '';
    };

    rec.onerror = (event) => {
        setListening(false);
        if (event.error === 'not-allowed') {
            showError('마이크 접근이 거부되었습니다. 브라우저 설정에서 허용해주세요.');
        } else if (event.error !== 'aborted' && event.error !== 'no-speech') {
            showError(`음성 인식 오류: ${event.error}`);
        }
    };

    return rec;
}

function setListening(listening) {
    isListening = listening;
    micBtn.classList.toggle('listening', listening);
    statusEl.textContent = listening ? '듣고 있습니다...' : '';
}

function toggleMicLang() {
    if (isListening) return;
    micLang = micLang === 'ko' ? 'ja' : 'ko';
    micLangLabel.textContent = micLang === 'ko' ? 'KO' : 'JA';
    document.getElementById('micLangBtn').classList.toggle('ja-mode', micLang === 'ja');
    saveSettings();
}

function resetSilenceTimer() {
    clearTimeout(silenceTimer);
    const val = getSilenceTimeout();
    if (val === 'auto' || val === '0') return;
    silenceTimer = setTimeout(() => {
        if (isListening) stopMic();
    }, parseInt(val));
}

// ===== OpenAI STT =====
let mediaRecorder = null;
let audioChunks = [];

async function startOpenAIRecording(lang) {
    try {
        const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
        audioChunks = [];
        mediaRecorder = new MediaRecorder(stream, { mimeType: 'audio/webm;codecs=opus' });
        mediaRecorder.ondataavailable = (e) => { if (e.data.size > 0) audioChunks.push(e.data); };
        mediaRecorder.onstop = async () => {
            stream.getTracks().forEach(t => t.stop());
            if (audioChunks.length === 0) return;
            const blob = new Blob(audioChunks, { type: 'audio/webm' });
            if (blob.size < 1000) return;
            statusEl.textContent = '음성 인식 중...';
            try {
                const formData = new FormData();
                formData.append('file', blob, 'audio.webm');
                formData.append('lang', lang);
                const res = await fetch('/api/stt', { method: 'POST', body: formData });
                if (!res.ok) { const err = await res.json().catch(() => ({})); throw new Error(err.detail || 'STT 실패'); }
                const data = await res.json();
                statusEl.textContent = '';
                if (data.text?.trim()) handleSpeechResult(data.text.trim());
            } catch (err) { statusEl.textContent = ''; showError(err.message); }
        };
        mediaRecorder.start();
        return true;
    } catch (e) { showError('마이크 접근이 거부되었습니다.'); return false; }
}

function stopOpenAIRecording() {
    if (mediaRecorder?.state === 'recording') mediaRecorder.stop();
    mediaRecorder = null;
}

function startMic() {
    if (isListening || isProcessing) return;
    if (isMirrorListening) stopMirrorMic();

    const welcome = chatContainer.querySelector('.welcome-msg');
    if (welcome) welcome.remove();

    if (getSttMode() === 'openai') {
        interimText.textContent = '녹음 중... (버튼을 다시 눌러 중지)';
        startOpenAIRecording(micLang).then(ok => { if (ok) setListening(true); });
    } else {
        recognition = initRecognition();
        if (!recognition) return;
        try {
            recognition.start();
            setListening(true);
            resetSilenceTimer();
        } catch (e) { showError('마이크를 시작할 수 없습니다.'); }
    }
}

function stopMic() {
    if (!isListening) return;
    clearTimeout(silenceTimer);
    if (getSttMode() === 'openai') {
        interimText.textContent = '';
        stopOpenAIRecording();
        setListening(false);
    } else {
        recognition?.stop();
        setListening(false);
    }
}

// ===== Translation =====
async function handleSpeechResult(text, forceDirection) {
    if (isProcessing) return;
    isProcessing = true;

    const direction = forceDirection || (detectLang(text) === 'ko' ? 'ko2ja' : 'ja2ko');
    const msgSide = direction === 'ko2ja' ? 'ko' : 'ja';

    const loadingEl = showLoading();

    try {
        const translateRes = await fetch('/api/translate', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ text, direction, context: conversationContext }),
        });

        if (!translateRes.ok) {
            const errData = await translateRes.json().catch(() => ({}));
            throw new Error(errData.detail || '번역 실패');
        }
        const data = await translateRes.json();

        loadingEl.remove();

        const msgEl = createMessageBubble(text, data.translated, data.back_translation, msgSide);
        chatContainer.appendChild(msgEl);

        const mirrorEl = createMessageBubble(text, data.translated, data.back_translation, msgSide);
        chatMirror.appendChild(mirrorEl);

        scrollToBottom();

        conversationContext.push({
            original: text,
            translated: data.translated,
            direction,
        });

        const ttsLang = direction === 'ko2ja' ? 'ja' : 'ko';
        const shouldPlay = (ttsLang === 'ja' && ttsJaEnabled) || (ttsLang === 'ko' && ttsKoEnabled);
        if (shouldPlay) {
            const voice = ttsLang === 'ja'
                ? document.getElementById('voiceJa').value
                : document.getElementById('voiceKo').value;
            playTTS(data.translated, ttsLang, voice);
        }
    } catch (err) {
        loadingEl.remove();
        showError(err.message);
    } finally {
        isProcessing = false;
    }
}

// ===== Message Bubble =====
function createMessageBubble(original, translated, backTranslation, side) {
    const msg = document.createElement('div');
    msg.className = `message ${side}`;

    const langTag = side === 'ko' ? 'KO→JA' : 'JA→KO';

    let html = `<div class="bubble">`;
    html += `<div class="lang-tag">${langTag}</div>`;
    html += `<div class="original-text">${escapeHtml(original)}</div>`;
    html += `<div class="translated-text">${escapeHtml(translated)}</div>`;

    if (backTranslation) {
        html += `<div class="back-translation">(${escapeHtml(backTranslation)})</div>`;
    }

    html += `<button class="replay-btn" data-text="${escapeAttr(translated)}" data-lang="${side === 'ko' ? 'ja' : 'ko'}">
        <svg viewBox="0 0 24 24" fill="currentColor"><path d="M3 9v6h4l5 5V4L7 9H3zm13.5 3c0-1.77-1.02-3.29-2.5-4.03v8.05c1.48-.73 2.5-2.25 2.5-4.02z"/></svg>
        다시 듣기
    </button>`;
    html += `</div>`;

    msg.innerHTML = html;

    msg.querySelector('.replay-btn').addEventListener('click', (e) => {
        const btn = e.currentTarget;
        const replayVoice = btn.dataset.lang === 'ja'
            ? document.getElementById('voiceJa').value
            : document.getElementById('voiceKo').value;
        playTTS(btn.dataset.text, btn.dataset.lang, replayVoice);
    });

    return msg;
}

function showLoading() {
    const el = document.createElement('div');
    el.className = 'loading-bubble';
    el.innerHTML = '<div class="loading-dot"></div><div class="loading-dot"></div><div class="loading-dot"></div>';
    chatContainer.appendChild(el);
    scrollToBottom();
    return el;
}

// ===== TTS =====
const canStreamAudio = window.MediaSource && MediaSource.isTypeSupported('audio/mpeg');

async function playTTS(text, lang, voice) {
    try {
        statusEl.textContent = '음성 생성 중...';
        const body = { text, lang };
        if (voice) body.voice = voice;
        const res = await fetch('/api/tts', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(body),
        });

        if (!res.ok) {
            const errData = await res.json().catch(() => ({}));
            console.error('TTS error:', errData.detail || res.status);
            statusEl.textContent = '';
            showError(errData.detail || 'TTS 실패');
            return;
        }

        if (canStreamAudio) {
            await playTTSStream(res);
        } else {
            await playTTSBlob(res);
        }
    } catch (err) {
        console.error('TTS error:', err);
        statusEl.textContent = '';
    }
}

async function playTTSStream(res) {
    const mediaSource = new MediaSource();
    const audio = new Audio();
    audio.src = URL.createObjectURL(mediaSource);

    function waitForBuffer(sb) {
        return new Promise(r => {
            if (!sb.updating) return r();
            const onEnd = () => { sb.removeEventListener('updateend', onEnd); r(); };
            sb.addEventListener('updateend', onEnd);
        });
    }

    return new Promise((resolve) => {
        mediaSource.addEventListener('sourceopen', async () => {
            let sourceBuffer;
            try {
                sourceBuffer = mediaSource.addSourceBuffer('audio/mpeg');
            } catch (e) {
                URL.revokeObjectURL(audio.src);
                await playTTSBlob(res);
                resolve();
                return;
            }

            const reader = res.body.getReader();
            const chunks = [];
            let appendRunning = false;

            async function flushChunks() {
                if (appendRunning) return;
                appendRunning = true;
                while (chunks.length > 0) {
                    const chunk = chunks.shift();
                    await waitForBuffer(sourceBuffer);
                    try {
                        sourceBuffer.appendBuffer(chunk);
                    } catch (e) {
                        console.error('appendBuffer error:', e);
                        break;
                    }
                    await waitForBuffer(sourceBuffer);
                }
                appendRunning = false;
            }

            statusEl.textContent = '재생 중...';
            audio.play().catch(() => {
                showError('자동 재생이 차단되었습니다. 다시 듣기 버튼을 눌러주세요.');
            });

            try {
                while (true) {
                    const { done, value } = await reader.read();
                    if (done) break;
                    chunks.push(value);
                    flushChunks();
                }
                // Flush remaining
                await flushChunks();
                await waitForBuffer(sourceBuffer);
                if (mediaSource.readyState === 'open') {
                    mediaSource.endOfStream();
                }
            } catch (e) {
                console.error('Stream error:', e);
            }
        });

        audio.onended = () => {
            URL.revokeObjectURL(audio.src);
            statusEl.textContent = '';
            resolve();
        };

        audio.onerror = () => {
            URL.revokeObjectURL(audio.src);
            statusEl.textContent = '';
            resolve();
        };
    });
}

async function playTTSBlob(res) {
    const blob = await res.blob();
    if (blob.size === 0) return;
    const url = URL.createObjectURL(blob);
    const audio = new Audio(url);
    audio.onended = () => { URL.revokeObjectURL(url); statusEl.textContent = ''; };
    audio.onerror = () => { URL.revokeObjectURL(url); statusEl.textContent = ''; };
    statusEl.textContent = '재생 중...';
    await audio.play().catch(() => {
        showError('자동 재생이 차단되었습니다. 다시 듣기 버튼을 눌러주세요.');
        statusEl.textContent = '';
    });
}

// ===== Utilities =====
function showError(msg) {
    const toast = document.createElement('div');
    toast.className = 'error-toast';
    toast.textContent = msg;
    document.body.appendChild(toast);
    setTimeout(() => toast.remove(), 4000);
}

function scrollToBottom() {
    requestAnimationFrame(() => {
        chatContainer.scrollTop = chatContainer.scrollHeight;
        chatMirror.scrollTop = chatMirror.scrollHeight;
    });
}

function escapeHtml(text) {
    const div = document.createElement('div');
    div.textContent = text;
    return div.innerHTML;
}

function escapeAttr(text) {
    return text.replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

function sendText() {
    const text = textInput.value.trim();
    if (!text || isProcessing) return;

    const welcome = chatContainer.querySelector('.welcome-msg');
    if (welcome) welcome.remove();

    textInput.value = '';

    // Realtime mode with active session: send text via data channel
    if (realtimeActive && dataChannel?.readyState === 'open') {
        dataChannel.send(JSON.stringify({
            type: 'conversation.item.create',
            item: {
                type: 'message',
                role: 'user',
                content: [{ type: 'input_text', text }],
            },
        }));
        dataChannel.send(JSON.stringify({ type: 'response.create' }));
        currentInputTranscript = text;
        return;
    }

    // Normal/OpenAI mode: use existing ping-pong
    handleSpeechResult(text);
}

// ===== Event Listeners =====
micBtn.addEventListener('click', () => {
    if (getSttMode() === 'realtime') {
        if (realtimeActive) { stopRealtimeSession(); } else { startRealtimeSession(); }
    } else {
        if (isListening) { stopMic(); } else { startMic(); }
    }
});

sendBtn.addEventListener('click', sendText);
document.getElementById('micLangBtn').addEventListener('click', toggleMicLang);

document.getElementById('fontSizeSetting').addEventListener('change', (e) => {
    document.documentElement.style.fontSize = e.target.value + 'px';
    saveSettings();
});

document.getElementById('ttsJaToggle').addEventListener('click', () => {
    ttsJaEnabled = !ttsJaEnabled;
    document.querySelector('#ttsJaToggle .toggle-dot').classList.toggle('on', ttsJaEnabled);
    updateRealtimeAudioMute();
    saveSettings();
});

document.getElementById('ttsKoToggle').addEventListener('click', () => {
    ttsKoEnabled = !ttsKoEnabled;
    document.querySelector('#ttsKoToggle .toggle-dot').classList.toggle('on', ttsKoEnabled);
    updateRealtimeAudioMute();
    saveSettings();
});

function updateRealtimeAudioMute() {
    if (realtimeAudioEl) {
        realtimeAudioEl.muted = !ttsJaEnabled && !ttsKoEnabled;
    }
}

document.getElementById('voiceJa').addEventListener('change', saveSettings);
document.getElementById('voiceKo').addEventListener('change', saveSettings);
document.getElementById('silenceTimeout').addEventListener('change', saveSettings);
document.getElementById('sttMode').addEventListener('change', () => {
    // Clean up any active sessions when switching modes
    if (isListening) stopMic();
    if (isMirrorListening) stopMirrorMic();
    if (realtimeActive) stopRealtimeSession();
    updateModeUI();
    saveSettings();
});

function getSttMode() {
    return document.getElementById('sttMode').value;
}

function updateModeUI() {
    const app = document.querySelector('.app');
    const isRealtime = getSttMode() === 'realtime';
    app.classList.toggle('realtime-active', isRealtime);
}

textInput.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && !e.isComposing) {
        e.preventDefault();
        sendText();
    }
});

// ===== Mirror mic (Japanese side) =====
const mirrorMicBtn = document.getElementById('mirrorMicBtn');
const mirrorStatusEl = document.getElementById('mirrorStatus');
const mirrorInterimEl = document.getElementById('mirrorInterim');

function initMirrorRecognition() {
    if (!SpeechRecognition) return null;

    const rec = new SpeechRecognition();
    rec.lang = 'ja-JP';
    const isAuto = getSilenceTimeout() === 'auto';
    rec.continuous = !isAuto;
    rec.interimResults = true;
    rec.maxAlternatives = 1;

    rec.onresult = (event) => {
        let interim = '';
        for (let i = event.resultIndex; i < event.results.length; i++) {
            const transcript = event.results[i][0].transcript;
            if (event.results[i].isFinal) {
                mirrorFinalTranscript += transcript;
            } else {
                interim += transcript;
            }
        }
        mirrorInterimEl.textContent = mirrorFinalTranscript + interim;
        resetMirrorSilenceTimer();
    };

    rec.onend = () => {
        setMirrorListening(false);
        mirrorInterimEl.textContent = '';
        if (mirrorFinalTranscript.trim()) {
            handleSpeechResult(mirrorFinalTranscript.trim(), 'ja2ko');
        }
        mirrorFinalTranscript = '';
    };

    rec.onerror = (event) => {
        setMirrorListening(false);
        if (event.error === 'not-allowed') {
            showError('マイクへのアクセスが拒否されました。');
        }
    };

    return rec;
}

function setMirrorListening(listening) {
    isMirrorListening = listening;
    mirrorMicBtn.classList.toggle('listening', listening);
    mirrorStatusEl.textContent = listening ? '聞いています...' : '';
}

function resetMirrorSilenceTimer() {
    clearTimeout(mirrorSilenceTimer);
    const val = getSilenceTimeout();
    if (val === 'auto' || val === '0') return;
    mirrorSilenceTimer = setTimeout(() => {
        if (isMirrorListening) stopMirrorMic();
    }, parseInt(val));
}

let mirrorMediaRecorder = null;
let mirrorAudioChunks = [];

function startMirrorMic() {
    if (isMirrorListening || isProcessing) return;
    if (isListening) stopMic();

    const welcome = chatContainer.querySelector('.welcome-msg');
    if (welcome) welcome.remove();

    if (getSttMode() === 'openai') {
        (async () => {
            try {
                const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
                mirrorAudioChunks = [];
                mirrorMediaRecorder = new MediaRecorder(stream, { mimeType: 'audio/webm;codecs=opus' });
                mirrorMediaRecorder.ondataavailable = (e) => { if (e.data.size > 0) mirrorAudioChunks.push(e.data); };
                mirrorMediaRecorder.onstop = async () => {
                    stream.getTracks().forEach(t => t.stop());
                    if (mirrorAudioChunks.length === 0) return;
                    const blob = new Blob(mirrorAudioChunks, { type: 'audio/webm' });
                    if (blob.size < 1000) return;
                    mirrorStatusEl.textContent = '音声認識中...';
                    try {
                        const formData = new FormData();
                        formData.append('file', blob, 'audio.webm');
                        formData.append('lang', 'ja');
                        const res = await fetch('/api/stt', { method: 'POST', body: formData });
                        if (!res.ok) { const err = await res.json().catch(() => ({})); throw new Error(err.detail || 'STT失敗'); }
                        const data = await res.json();
                        mirrorStatusEl.textContent = '';
                        if (data.text?.trim()) handleSpeechResult(data.text.trim(), 'ja2ko');
                    } catch (err) { mirrorStatusEl.textContent = ''; showError(err.message); }
                };
                mirrorMediaRecorder.start();
                mirrorInterimEl.textContent = '録音中... (ボタンを押して停止)';
                setMirrorListening(true);
            } catch (e) { showError('マイクへのアクセスが拒否されました。'); }
        })();
    } else {
        mirrorRecognition = initMirrorRecognition();
        if (!mirrorRecognition) return;
        try {
            mirrorRecognition.start();
            setMirrorListening(true);
            resetMirrorSilenceTimer();
        } catch (e) { showError('マイクを開始できません。'); }
    }
}

function stopMirrorMic() {
    if (!isMirrorListening) return;
    clearTimeout(mirrorSilenceTimer);
    if (getSttMode() === 'openai') {
        mirrorInterimEl.textContent = '';
        if (mirrorMediaRecorder?.state === 'recording') mirrorMediaRecorder.stop();
        mirrorMediaRecorder = null;
        setMirrorListening(false);
    } else {
        mirrorRecognition?.stop();
        setMirrorListening(false);
    }
}

mirrorMicBtn.addEventListener('click', () => {
    if (isMirrorListening) { stopMirrorMic(); } else { startMirrorMic(); }
});

// ===== Realtime API (WebRTC) =====
let realtimeActive = false;
let peerConnection = null;
let dataChannel = null;
let realtimeAudioEl = null;
let localStream = null;
let localTrack = null;

// Track current turn's transcription and translation
let currentInputTranscript = '';
let currentOutputTranscript = '';
let isMuted = false;

async function startRealtimeSession() {
    if (realtimeActive) return;

    const welcome = chatContainer.querySelector('.welcome-msg');
    if (welcome) welcome.remove();

    statusEl.textContent = 'Realtime 연결 중...';
    micBtn.classList.add('realtime-session');

    try {
        // 1. Get ephemeral token from backend
        const voice = document.getElementById('voiceJa').value;
        const tokenRes = await fetch('/api/realtime/session', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ voice }),
        });

        if (!tokenRes.ok) {
            const err = await tokenRes.json().catch(() => ({}));
            throw new Error(err.detail || 'Realtime 세션 생성 실패');
        }

        const tokenData = await tokenRes.json();
        const ephemeralKey = tokenData.value || tokenData.client_secret?.value;

        if (!ephemeralKey) throw new Error('토큰을 받을 수 없습니다');

        // 2. Create WebRTC peer connection
        peerConnection = new RTCPeerConnection();

        // 3. Audio output — translated speech plays here
        realtimeAudioEl = document.createElement('audio');
        realtimeAudioEl.autoplay = true;
        // Respect TTS toggle — mute audio if both TTS are off
        realtimeAudioEl.muted = !ttsJaEnabled && !ttsKoEnabled;
        peerConnection.ontrack = (e) => {
            realtimeAudioEl.srcObject = e.streams[0];
        };

        // 4. Microphone input
        localStream = await navigator.mediaDevices.getUserMedia({ audio: true });
        localTrack = localStream.getTracks()[0];
        peerConnection.addTrack(localTrack, localStream);

        // 5. Data channel for events
        dataChannel = peerConnection.createDataChannel('oai-events');
        dataChannel.addEventListener('open', () => {
            // Configure session after data channel opens
            console.log('Realtime data channel opened');
        });
        dataChannel.addEventListener('message', handleRealtimeEvent);

        // 6. SDP exchange
        const offer = await peerConnection.createOffer();
        await peerConnection.setLocalDescription(offer);

        const sdpRes = await fetch(
            'https://api.openai.com/v1/realtime/calls',
            {
                method: 'POST',
                headers: {
                    'Authorization': `Bearer ${ephemeralKey}`,
                    'Content-Type': 'application/sdp',
                },
                body: offer.sdp,
            }
        );

        if (!sdpRes.ok) throw new Error('WebRTC 연결 실패');

        const answer = {
            type: 'answer',
            sdp: await sdpRes.text(),
        };
        await peerConnection.setRemoteDescription(answer);

        realtimeActive = true;
        statusEl.textContent = 'Realtime 활성 — 말하세요';
        interimText.textContent = '';

    } catch (err) {
        console.error('Realtime session error:', err);
        showError(err.message);
        cleanupRealtime();
        statusEl.textContent = '';
        micBtn.classList.remove('realtime-session');
    }
}

function stopRealtimeSession() {
    cleanupRealtime();
    statusEl.textContent = '';
    micBtn.classList.remove('realtime-session');
}

function cleanupRealtime() {
    realtimeActive = false;
    isMuted = false;

    if (dataChannel) {
        dataChannel.close();
        dataChannel = null;
    }
    if (peerConnection) {
        peerConnection.close();
        peerConnection = null;
    }
    if (localStream) {
        localStream.getTracks().forEach(t => t.stop());
        localStream = null;
        localTrack = null;
    }
    if (realtimeAudioEl) {
        realtimeAudioEl.srcObject = null;
        realtimeAudioEl = null;
    }
    currentInputTranscript = '';
    currentOutputTranscript = '';
}

function muteRealtimeMic(mute) {
    if (localTrack) {
        localTrack.enabled = !mute;
        isMuted = mute;
    }
}

function handleRealtimeEvent(e) {
    let event;
    try {
        event = JSON.parse(e.data);
    } catch {
        return;
    }

    // Log all events for debugging (exclude noisy audio deltas)
    if (event.type !== 'response.audio.delta') {
        console.log('RT event:', event.type, event);
    }

    switch (event.type) {
        // User started speaking
        case 'input_audio_buffer.speech_started':
            interimText.textContent = '듣고 있습니다...';
            mirrorInterimEl.textContent = '聞いています...';
            break;

        // User stopped speaking
        case 'input_audio_buffer.speech_stopped':
            interimText.textContent = '번역 중...';
            mirrorInterimEl.textContent = '翻訳中...';
            break;

        // User's audio item completed — extract transcript if available
        case 'conversation.item.done':
            if (event.item?.type === 'message' && event.item?.role === 'user') {
                const audioContent = event.item.content?.find(c => c.type === 'input_audio');
                if (audioContent?.transcript) {
                    currentInputTranscript = audioContent.transcript;
                    interimText.textContent = currentInputTranscript;
                    mirrorInterimEl.textContent = currentInputTranscript;
                }
            }
            break;

        // Model starts generating audio — mute mic to prevent feedback
        case 'output_audio_buffer.started':
            if (!isMuted) muteRealtimeMic(true);
            break;

        // Translated text streaming
        case 'response.output_audio_transcript.delta':
            currentOutputTranscript += (event.delta || '');
            interimText.textContent = currentOutputTranscript;
            mirrorInterimEl.textContent = currentOutputTranscript;
            break;

        // Audio output finished — unmute
        case 'output_audio_buffer.stopped':
            setTimeout(() => muteRealtimeMic(false), 300);
            break;

        // Response complete — create bubble, then async fetch back-translation
        case 'response.done':
            if (currentOutputTranscript) {
                const outputLang = detectLang(currentOutputTranscript);
                const side = outputLang === 'ja' ? 'ko' : 'ja';
                const original = currentInputTranscript || '';
                const translated = currentOutputTranscript;

                // Create bubble immediately with what we have
                const msgEl = createMessageBubble(
                    original || translated, translated, null, side
                );
                chatContainer.appendChild(msgEl);

                const mirrorEl = createMessageBubble(
                    original || translated, translated, null, side
                );
                chatMirror.appendChild(mirrorEl);

                scrollToBottom();

                // Async: reverse-translate to get original text + verification
                const reverseDir = outputLang === 'ja' ? 'ja2ko' : 'ko2ja';
                fetch('/api/translate', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ text: translated, direction: reverseDir, context: [] }),
                }).then(r => r.json()).then(data => {
                    if (data.translated) {
                        // Update original text and add back-translation
                        const update = (el) => {
                            const origEl = el.querySelector('.original-text');
                            const bubble = el.querySelector('.bubble');
                            if (origEl) origEl.textContent = data.translated;
                            // Add back-translation if not exists
                            if (!el.querySelector('.back-translation')) {
                                const btEl = document.createElement('div');
                                btEl.className = 'back-translation';
                                btEl.textContent = `(${data.translated})`;
                                bubble.querySelector('.translated-text').after(btEl);
                            }
                        };
                        update(msgEl);
                        update(mirrorEl);
                    }
                }).catch(() => {}); // silent fail for back-translation
            }

            currentInputTranscript = '';
            currentOutputTranscript = '';
            interimText.textContent = '';
            mirrorInterimEl.textContent = '';
            break;

        case 'error':
            console.error('Realtime error:', event.error);
            showError('Realtime 오류: ' + (event.error?.message || '알 수 없는 오류'));
            break;
    }
}

// Cleanup on page unload
window.addEventListener('beforeunload', () => {
    if (realtimeActive) cleanupRealtime();
});

// ===== Init =====
loadSettings();
updateModeUI();
