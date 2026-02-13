#!/usr/bin/env npx ts-node
/**
 * Test script for OLLAMA_HOST cross-machine discovery patch
 *
 * Run with: OLLAMA_HOST=http://192.168.15.6:30068 npx ts-node test-ollama-discovery.ts
 * Or on Mac Studio: npx ts-node test-ollama-discovery.ts (uses localhost default)
 */

// Replicate the patched functions exactly
function getOllamaApiBaseUrl(): string {
  return process.env.OLLAMA_HOST?.replace(/\/$/, "") ?? "http://127.0.0.1:11434";
}

function getOllamaBaseUrl(): string {
  const host = process.env.OLLAMA_HOST?.replace(/\/$/, "") ?? "http://127.0.0.1:11434";
  return `${host}/v1`;
}

interface OllamaModel {
  name: string;
  details?: {
    family?: string;
    parameter_size?: string;
  };
}

interface OllamaTagsResponse {
  models: OllamaModel[];
}

async function discoverOllamaModels(): Promise<void> {
  const ollamaApiBase = getOllamaApiBaseUrl();
  console.log(`\n🔍 Testing Ollama discovery`);
  console.log(`   OLLAMA_HOST env: ${process.env.OLLAMA_HOST ?? "(not set)"}`);
  console.log(`   API base URL: ${ollamaApiBase}`);
  console.log(`   OpenAI base URL: ${getOllamaBaseUrl()}`);
  console.log("");

  try {
    const response = await fetch(`${ollamaApiBase}/api/tags`, {
      signal: AbortSignal.timeout(5000),
    });

    if (!response.ok) {
      console.error(`❌ Failed: HTTP ${response.status}`);
      return;
    }

    const data = (await response.json()) as OllamaTagsResponse;

    if (!data.models || data.models.length === 0) {
      console.warn(`⚠️  No models found at ${ollamaApiBase}`);
      return;
    }

    console.log(`✅ Found ${data.models.length} models:\n`);
    data.models.forEach((model, i) => {
      const size = model.details?.parameter_size ?? "unknown";
      const family = model.details?.family ?? "unknown";
      console.log(`   ${i + 1}. ${model.name} (${size}, ${family})`);
    });

    console.log(`\n✅ Cross-machine discovery working!`);
    console.log(`   OpenClaw would use baseUrl: ${getOllamaBaseUrl()}`);

  } catch (error) {
    console.error(`❌ Failed to discover models from ${ollamaApiBase}:`);
    console.error(`   ${String(error)}`);
  }
}

discoverOllamaModels();
