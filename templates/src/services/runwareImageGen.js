/**
 * Cleanified Runware Image Generation Module
 * 
 * Standalone utility for generating images via the Runware API.
 * - Loads model configs from a JavaScript file.
 * - Supports prompt modification hooks for certain model types.
 * - Handles all request/response and logs to file/console.
 * 
 * Usage:
 *   generateImage("a cat on a bike", "AnimeStyle🌸")
 *     .then(result => console.log(result))
 *     .catch(console.error);
 */

import dotenv from 'dotenv';
dotenv.config();
import fetch from 'node-fetch';
import fs from 'fs';
import path from 'path';
import { v4 as uuidv4 } from 'uuid';
import { fileURLToPath } from 'url';

// Create __dirname equivalent for ES modules
const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// Path to config and log files
const CONFIG_FILE = './runwareImageGen_models.js';
const LOG_FILE = path.join(process.cwd(), "image_generation.log");

// --- Logging helpers ---

/**
 * Log a message to console and log file (with timestamp)
 */
function logMessage(message) {
  const timestamp = new Date().toISOString();
  const formattedMessage = `[${timestamp}] ${message}\n`;
  console.log(message);
  fs.appendFileSync(LOG_FILE, formattedMessage, "utf8");
}

// --- Config loading ---

const DEFAULT_MODEL_CONFIG = {
  id_name: "Basic✔",
  model: "rundiffusion:120@100",
  credit_cost: 1,
  positivePrompt: "",
  negativePrompt: "",
  width: 1024,
  height: 1024,
  numberResults: 1,
  outputType: ["URL"],
  outputFormat: "PNG",
  checkNSFW: false,
  steps: 28,
  scheduler: "Euler",
  seed: null,
  CFGScale: 3.5,
  clipSkip: 1,
  usePromptWeighting: 1,
  retry: 2,
  controlNet: [],
  lora: [],
  refiner: null
};

/**
 * Loads model config from JavaScript file
 */
async function loadConfigFromJS(filename = CONFIG_FILE) {
  try {
    const filePath = path.resolve(__dirname, filename);
    logMessage(`Loading config: ${filePath}`);
    
    if (fs.existsSync(filePath)) {
      // Dynamic import for ES modules
      const configModule = await import(`file://${filePath}`);
      
      // Handle different export patterns
      if (configModule.default) {
        return configModule.default;
      } else if (configModule.runwareModelConfig) {
        return configModule.runwareModelConfig;
      } else {
        // If the file exports the config directly
        return configModule;
      }
    }
    
    logMessage(`Config file not found: ${filePath}. Using defaults.`);
    return {};
  } catch (error) {
    logMessage(`Error loading config: ${error.message}`);
    return {};
  }
}

/**
 * Get a model config by ID from config file, fallback to default
 */
async function getModelConfigById(id_name) {
  const runwareConfigs = await loadConfigFromJS();
  const configs = runwareConfigs.aiModelConfigs || [DEFAULT_MODEL_CONFIG];
  const found = configs.find(cfg => cfg.id_name === id_name);
  if (!found) {
    logMessage(`Model config not found for ${id_name}. Using default.`);
    return DEFAULT_MODEL_CONFIG;
  }
  return found;
}

// --- Prompt helpers ---

/**
 * Optionally modify prompt for special model types.
 * (Extend or customize as needed.)
 */
function tweakPromptForModel(prompt, modelId) {
  if (modelId === "NSFW📛") {
    return `score_9, score_8_up, score_7_up, raw, amateur, film grain, masterpiece, high quality, detailed, max details, ${prompt}`;
  }
  if (modelId === "NSFW2📛") {
    return `sexy, erotic, naked, nude scene, porn, raw, amateur, film grain, masterpiece, high quality, detailed, max details, ${prompt}`;
  }
  if (modelId === "NSFW3📛") {
    return `Stable_Yogis_PDXL_Positives2, ${prompt}`;
  }
  return prompt;
}

// --- Main API function ---

/**
 * Generate an image using Runware API, with a given prompt and model ID.
 * @param {string} prompt - Text prompt
 * @param {string} modelId - Model id_name from config
 * @returns {Promise<Object>} Result info
 */
export default async function generateImage(prompt, modelId = "Basic✔") {
  try {
    logMessage(`Request to generate image with model "${modelId}" and prompt: ${prompt}`);

    // 1. Get model config
    const modelConfig = await getModelConfigById(modelId);
    logMessage(`Using model config: ${JSON.stringify(modelConfig, null, 2)}`);

    // 2. Prepare prompt
    const finalPrompt = tweakPromptForModel(prompt, modelId);

    // 3. Build parameters
    const params = {
      taskType: "imageInference",
      positivePrompt: finalPrompt,
      model: modelConfig.model,
      width: modelConfig.width,
      height: modelConfig.height,
      numberResults: modelConfig.numberResults || 1,
      outputType: modelConfig.outputType || ["URL"],
      outputFormat: modelConfig.outputFormat || "PNG",
      checkNSFW: modelConfig.checkNSFW !== undefined ? modelConfig.checkNSFW : false,
      includeCost: true,
      steps: modelConfig.steps,
      scheduler: modelConfig.scheduler,
      seed: modelConfig.seed,
      CFGScale: modelConfig.CFGScale,
      clipSkip: modelConfig.clipSkip,
      usePromptWeighting: modelConfig.usePromptWeighting,
      retry: modelConfig.retry,
      taskUUID: uuidv4()
    };
    
    if (modelConfig.outputQuality !== undefined) params.outputQuality = modelConfig.outputQuality;
    if (modelConfig.lora && modelConfig.lora.length > 0) params.lora = modelConfig.lora;
    if (modelConfig.embedding && modelConfig.embedding.length > 0) params.embedding = modelConfig.embedding;
    if (modelConfig.controlNet && modelConfig.controlNet.length > 0) params.controlNet = modelConfig.controlNet;
    if (modelConfig.refiner) params.refiner = modelConfig.refiner;

    // ---- Only include negativePrompt if not empty/non-whitespace ----
    if (modelConfig.negativePrompt && modelConfig.negativePrompt.trim() !== "") {
      params.negativePrompt = modelConfig.negativePrompt;
    }
    // ---------------------------------------------------------------

    // 4. Send API request
    logMessage(`Runware payload: ${JSON.stringify([params], null, 2)}`);
    
    logMessage('Making request to Runware API...');
    const res = await fetch('https://api.runware.ai/v1', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${process.env.RUNWARE_API_KEY}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify([params]),
    });

    logMessage(`API Response received - status: ${res.status}`);

    if (!res.ok) {
      const errText = await res.text();
      logMessage(`API Error: ${res.status} ${errText}`);
      throw new Error(`API Error: ${res.status} ${errText}`);
    }
    
    const data = await res.json();
    logMessage(`API Response data: ${JSON.stringify(data, null, 2)}`);
    
    const response = data.data?.[0];
    if (!response) throw new Error('No response data from Runware API');

    const imageDetails = {
      ...response,
      imageUrl: response.imageURL,
      prompt: finalPrompt,
      originalPrompt: prompt,
      dimensions: { width: params.width, height: params.height },
      model: params.model,
      idName: modelId,
      configuration: { ...params, positivePrompt: undefined }
    };

    logMessage(`Image generated successfully! URL: ${imageDetails.imageUrl}`);

    return imageDetails;

  } catch (error) {
    logMessage(`generateImage error: ${error.message}`);
    logMessage(`Error stack: ${error.stack}`);
    throw error;
  }
}
