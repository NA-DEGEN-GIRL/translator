const chatContainer = document.getElementById('chatContainer');
const micBtn = document.getElementById('micBtn');
const micLangLabel = document.getElementById('micLangLabel');
const statusEl = document.getElementById('status');
const interimText = document.getElementById('interimText');
const textInput = document.getElementById('textInput');
const sendBtn = document.getElementById('sendBtn');

let isListening = false;
let recognition = null;
let conversationContext = [];
let micLang = 'ko';
let finalTranscript = '';
let silenceTimer = null;
let ttsJaEnabled = true;
let ttsKoEnabled = true;

// Detect language from text: Korean vs Japanese
function detectLang(text) {
    let ko = 0, ja = 0;
    for (const ch of text) {
        const code = ch.charCodeAt(0);
        // Hangul: AC00-D7AF (syllables), 1100-11FF (jamo), 3130-318F (compat jamo)
        if ((code >= 0xAC00 && code <= 0xD7AF) || (code >= 0x1100 && code <= 0x11FF) || (code >= 0x3130 && code <= 0x318F)) {
            ko++;
        }
        // Hiragana: 3040-309F, Katakana: 30A0-30FF, CJK: 4E00-9FFF
        if ((code >= 0x3040 && code <= 0x309F) || (code >= 0x30A0 && code <= 0x30FF)) {
            ja++;
        }
        // CJK characters are ambiguous but lean Japanese when mixed with kana
        if (code >= 0x4E00 && code <= 0x9FFF) {
            ja += 0.3;
        }
    }
    if (ko === 0 && ja === 0) return 'ko'; // default
    return ko >= ja ? 'ko' : 'ja';
}

// Check browser support
const SpeechRecognition = window.SpeechRecognition || window.webkitSpeechRecognition;
if (!SpeechRecognition) {
    showError('이 브라우저는 음성 인식을 지원하지 않습니다. Chrome을 사용해주세요.');
}

function initRecognition() {
    if (!SpeechRecognition) return null;

    const rec = new SpeechRecognition();
    rec.lang = micLang === 'ko' ? 'ko-KR' : 'ja-JP';
    rec.continuous = true;
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

        // Reset silence timer on any speech activity
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
}

function getSilenceTimeout() {
    return parseInt(document.getElementById('silenceTimeout').value);
}

function resetSilenceTimer() {
    clearTimeout(silenceTimer);
    const timeout = getSilenceTimeout();
    if (timeout === 0) return; // OFF
    silenceTimer = setTimeout(() => {
        if (isListening) stopMic();
    }, timeout);
}

function startMic() {
    if (isListening) return;

    recognition = initRecognition();
    if (!recognition) return;

    const welcome = chatContainer.querySelector('.welcome-msg');
    if (welcome) welcome.remove();

    try {
        recognition.start();
        setListening(true);
        resetSilenceTimer();
    } catch (e) {
        showError('마이크를 시작할 수 없습니다.');
    }
}

function stopMic() {
    if (!isListening) return;
    clearTimeout(silenceTimer);
    recognition?.stop();
    setListening(false);
}

async function handleSpeechResult(text) {
    const lang = detectLang(text);
    const direction = lang === 'ko' ? 'ko2ja' : 'ja2ko';
    const msgSide = lang === 'ko' ? 'ko' : 'ja';

    // Show loading
    const loadingEl = showLoading();

    try {
        // Translate
        const translateRes = await fetch('/api/translate', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ text, direction, context: conversationContext }),
        });

        if (!translateRes.ok) throw new Error('번역 실패');
        const data = await translateRes.json();

        // Remove loading
        loadingEl.remove();

        // Add message bubble
        const msgEl = createMessageBubble(text, data.translated, data.back_translation, msgSide);
        chatContainer.appendChild(msgEl);
        scrollToBottom();

        // Save context
        conversationContext.push({
            original: text,
            translated: data.translated,
            direction,
        });

        // TTS - play translated text (if enabled)
        const ttsLang = direction === 'ko2ja' ? 'ja' : 'ko';
        const shouldPlay = (ttsLang === 'ja' && ttsJaEnabled) || (ttsLang === 'ko' && ttsKoEnabled);
        if (shouldPlay) {
            playTTS(data.translated, ttsLang, msgEl);
        }

    } catch (err) {
        loadingEl.remove();
        showError(err.message);
    }
}

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
        playTTS(btn.dataset.text, btn.dataset.lang);
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

async function playTTS(text, lang, msgEl) {
    try {
        statusEl.textContent = '음성 생성 중...';
        const res = await fetch('/api/tts', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ text, lang }),
        });

        if (!res.ok) {
            console.error('TTS response error:', res.status);
            throw new Error('TTS 실패');
        }

        // Stream audio: start playing as chunks arrive
        const mediaSource = new MediaSource();
        const audio = new Audio();
        audio.src = URL.createObjectURL(mediaSource);

        mediaSource.addEventListener('sourceopen', async () => {
            const sourceBuffer = mediaSource.addSourceBuffer('audio/mpeg');
            const reader = res.body.getReader();

            statusEl.textContent = '재생 중...';
            audio.play().catch(() => {
                showError('자동 재생이 차단되었습니다. 다시 듣기 버튼을 눌러주세요.');
            });

            while (true) {
                const { done, value } = await reader.read();
                if (done) break;

                await new Promise(resolve => {
                    if (!sourceBuffer.updating) return resolve();
                    sourceBuffer.addEventListener('updateend', resolve, { once: true });
                });
                sourceBuffer.appendBuffer(value);
            }

            await new Promise(resolve => {
                if (!sourceBuffer.updating) return resolve();
                sourceBuffer.addEventListener('updateend', resolve, { once: true });
            });
            mediaSource.endOfStream();
        });

        audio.onended = () => {
            URL.revokeObjectURL(audio.src);
            statusEl.textContent = '';
        };

        audio.onerror = () => {
            URL.revokeObjectURL(audio.src);
            statusEl.textContent = '';
            playTTSFallback(text, lang);
        };
    } catch (err) {
        console.error('TTS error:', err);
        statusEl.textContent = '';
    }
}

async function playTTSFallback(text, lang) {
    try {
        const res = await fetch('/api/tts', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ text, lang }),
        });
        const blob = await res.blob();
        const url = URL.createObjectURL(blob);
        const audio = new Audio(url);
        audio.onended = () => { URL.revokeObjectURL(url); statusEl.textContent = ''; };
        statusEl.textContent = '재생 중...';
        await audio.play();
    } catch (err) {
        console.error('TTS fallback error:', err);
        statusEl.textContent = '';
    }
}

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
    if (!text) return;

    const welcome = chatContainer.querySelector('.welcome-msg');
    if (welcome) welcome.remove();

    textInput.value = '';
    handleSpeechResult(text);
}

// Event listeners — toggle mic
micBtn.addEventListener('click', () => {
    if (isListening) { stopMic(); } else { startMic(); }
});

sendBtn.addEventListener('click', sendText);
document.getElementById('micLangBtn').addEventListener('click', toggleMicLang);

document.getElementById('ttsJaToggle').addEventListener('click', () => {
    ttsJaEnabled = !ttsJaEnabled;
    document.querySelector('#ttsJaToggle .toggle-dot').classList.toggle('on', ttsJaEnabled);
});

document.getElementById('ttsKoToggle').addEventListener('click', () => {
    ttsKoEnabled = !ttsKoEnabled;
    document.querySelector('#ttsKoToggle .toggle-dot').classList.toggle('on', ttsKoEnabled);
});

textInput.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && !e.isComposing) {
        e.preventDefault();
        sendText();
    }
});
