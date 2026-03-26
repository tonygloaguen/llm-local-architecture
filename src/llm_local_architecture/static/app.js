const form = document.getElementById("chat-form");
const promptField = document.getElementById("prompt");
const documentField = document.getElementById("document");
const submitButton = document.getElementById("submit");
const responseNode = document.getElementById("response");
const modelNode = document.getElementById("model");
const ocrNode = document.getElementById("ocr");
const inputTypeNode = document.getElementById("input-type");
const memoryNode = document.getElementById("memory");

let sessionId = null;

function resetMeta() {
  modelNode.textContent = "-";
  ocrNode.textContent = "-";
  inputTypeNode.textContent = "-";
  memoryNode.textContent = "-";
}

form.addEventListener("submit", async (event) => {
  event.preventDefault();

  const formData = new FormData();
  formData.append("prompt", promptField.value);
  if (sessionId) {
    formData.append("session_id", sessionId);
  }
  if (documentField.files.length > 0) {
    formData.append("document", documentField.files[0]);
  }

  submitButton.disabled = true;
  resetMeta();
  responseNode.textContent = "Traitement en cours...";

  try {
    const response = await fetch("/chat", {
      method: "POST",
      body: formData,
    });
    const payload = await response.json();
    if (!response.ok) {
      throw new Error(payload.detail || "Erreur inconnue.");
    }

    sessionId = payload.session_id;
    responseNode.textContent = payload.response;
    modelNode.textContent = payload.model;
    ocrNode.textContent = payload.ocr_used ? "oui" : "non";
    inputTypeNode.textContent = payload.input_type;
    memoryNode.textContent = payload.memory_sources.join(", ") || "-";
  } catch (error) {
    resetMeta();
    responseNode.textContent = String(error.message || error);
  } finally {
    submitButton.disabled = false;
  }
});
