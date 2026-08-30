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

document.querySelectorAll("[data-copy]").forEach((button) => {
  button.addEventListener("click", async () => {
    const text = button.dataset.copy === "snippet" ? SNIPPET : INSTALL_COMMAND;
    try {
      await copyText(text);
      showToast(button.dataset.copy === "snippet" ? "Install and run command copied." : "Install command copied.");
    } catch {
      showToast("Unable to copy. Please select the command manually.");
    }
  });
});
