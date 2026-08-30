const INSTALL_COMMAND = "curl -fsSL https://raw.githubusercontent.com/jackson-lafrance/meringue/main/install.sh | sh";
const SNIPPET = `${INSTALL_COMMAND}\nmeringue`;

async function copyText(text) {
  if (navigator.clipboard && window.isSecureContext) {
    try {
      await navigator.clipboard.writeText(text);
      return;
    } catch {
      // Fall through to the older selection-based API when permissions deny it.
    }
  }
  const textarea = document.createElement("textarea");
  textarea.value = text;
  textarea.setAttribute("readonly", "");
  textarea.style.position = "fixed";
  textarea.style.opacity = "0";
  document.body.appendChild(textarea);
  textarea.select();
  textarea.setSelectionRange(0, textarea.value.length);
  const copied = document.execCommand("copy");
  textarea.remove();
  if (!copied) throw new Error("Clipboard unavailable");
}

function showToast(message) {
  const toast = document.querySelector(".toast");
  toast.textContent = message;
  toast.classList.add("visible");
  window.clearTimeout(showToast.timer);
  showToast.timer = window.setTimeout(() => toast.classList.remove("visible"), 3000);
}

const stageDescriptions = [
  ["Send a prompt", "Type a goal in the dashboard chat. You stay in the same terminal while Meringue takes it from here."],
  ["The head finds the fit", "A short lived head reads the project context and creates the issue in the right project."],
  ["A worker performs it", "The kernel gives the worker an isolated worktree and the worker starts the task."],
  ["Progress reaches complete", "Logs capture the result and the AgentTree shows the completed issue and worker."],
];
const stageButtons = [...document.querySelectorAll("[data-stage-button]")];
const stageViews = [...document.querySelectorAll("[data-stage]")];
const stageDescription = document.querySelector("#stage-description");
let currentStage = 0;

function showStage(stage, moveFocus = false) {
  currentStage = (stage + stageDescriptions.length) % stageDescriptions.length;
  stageViews.forEach((view) => { view.hidden = Number(view.dataset.stage) !== currentStage; });
  stageButtons.forEach((button) => {
    const selected = Number(button.dataset.stageButton) === currentStage;
    button.setAttribute("aria-selected", String(selected));
    button.tabIndex = selected ? 0 : -1;
  });
  stageDescription.querySelector("strong").textContent = stageDescriptions[currentStage][0];
  stageDescription.querySelector("span").textContent = stageDescriptions[currentStage][1];
  if (moveFocus) stageButtons[currentStage].focus();
}

stageButtons.forEach((button) => {
  button.addEventListener("click", () => showStage(Number(button.dataset.stageButton)));
  button.addEventListener("keydown", (event) => {
    if (event.key === "ArrowRight") { event.preventDefault(); showStage(currentStage + 1, true); }
    if (event.key === "ArrowLeft") { event.preventDefault(); showStage(currentStage - 1, true); }
    if (event.key === "Home") { event.preventDefault(); showStage(0, true); }
    if (event.key === "End") { event.preventDefault(); showStage(stageDescriptions.length - 1, true); }
  });
});
document.querySelectorAll("[data-carousel]").forEach((button) => {
  button.addEventListener("click", () => showStage(currentStage + (button.dataset.carousel === "next" ? 1 : -1), true));
});

showStage(0);

document.querySelectorAll("[data-copy]").forEach((button) => {
  button.addEventListener("click", async () => {
    const target = button.dataset.copyTarget && document.getElementById(button.dataset.copyTarget);
    const text = target ? target.textContent.trim() : (button.dataset.copyText || (button.dataset.copy === "snippet" ? SNIPPET : INSTALL_COMMAND));
    try {
      await copyText(text);
      showToast(button.dataset.copy === "snippet" ? "Install and run command copied." : "Command copied.");
    } catch {
      showToast("Unable to copy. Please select the command manually.");
    }
  });
});
