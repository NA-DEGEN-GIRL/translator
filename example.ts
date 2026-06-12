// To run this code you need to install the following dependencies:
// npm install @google/genai
// npm install -D @types/node
import {
  GoogleGenAI,
  LiveServerMessage,
  MediaResolution,
  Modality,
  Session,
} from '@google/genai';
const responseQueue: LiveServerMessage[] = [];
let session: Session | undefined = undefined;

async function handleTurn(): Promise<LiveServerMessage[]> {
  const turn: LiveServerMessage[] = [];
  let done = false;
  while (!done) {
    const message = await waitMessage();
    turn.push(message);
    if (message.serverContent && message.serverContent.turnComplete) {
      done = true;
    }
  }
  return turn;
}

async function waitMessage(): Promise<LiveServerMessage> {
  let done = false;
  let message: LiveServerMessage | undefined = undefined;
  while (!done) {
    message = responseQueue.shift();
    if (message) {
      handleModelTurn(message);
      done = true;
    } else {
      await new Promise((resolve) => { setTimeout(resolve, 100); });
    }
  }
  return message!;
}

function handleModelTurn(message: LiveServerMessage) {
  if(message.serverContent?.modelTurn?.parts) {
    const part = message.serverContent?.modelTurn?.parts?.[0];

    if(part?.fileData) {
      console.log(`File: ${part?.fileData.fileUri}`);
    }

    if(part?.text) {
      console.log(part?.text);
    }
  }
}

async function main() {
  const ai = new GoogleGenAI({
    apiKey: process.env['GEMINI_API_KEY'],
  });

  const model = 'models/gemini-3.5-live-translate-preview'

  const config = {
    responseModalities: [
        Modality.AUDIO,
    ],
    mediaResolution: MediaResolution.MEDIA_RESOLUTION_MEDIUM,
    contextWindowCompression: {
        triggerTokens: '0',
        slidingWindow: { targetTokens: '0' },
    },
    translationConfig: {
      targetLanguageCode: 'ja',
    },
  };

  session = await ai.live.connect({
    model,
    callbacks: {
      onopen: function () {
        console.debug('Opened');
      },
      onmessage: function (message: LiveServerMessage) {
        responseQueue.push(message);
      },
      onerror: function (e: ErrorEvent) {
        console.debug('Error:', e.message);
      },
      onclose: function (e: CloseEvent) {
        console.debug('Close:', e.reason);
      },
    },
    config
  });

  session.sendClientContent({
    turns: [
      `INSERT_INPUT_HERE`
    ]
  });

  await handleTurn();

  session.close();
}
main();


