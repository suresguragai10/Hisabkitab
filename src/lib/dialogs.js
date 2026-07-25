// Imperative replacement for window.confirm/prompt/alert, so call sites
// keep the same "await, then act" shape they already had (`if (!confirm(...))
// return;` -> `if (!(await confirmDialog(...))) return;`) without threading
// dialog state through every page. DialogHost (mounted once in App.jsx)
// renders whatever request is currently pending.
const listeners = new Set();
let state = null;

function setState(next) {
  state = next;
  listeners.forEach((fn) => fn(state));
}

export function subscribeDialog(fn) {
  listeners.add(fn);
  return () => listeners.delete(fn);
}

export function getDialogState() {
  return state;
}

export function confirmDialog(message, opts = {}) {
  return new Promise((resolve) => {
    setState({
      kind: "confirm",
      message,
      title: opts.title || "Please confirm",
      confirmLabel: opts.confirmLabel || "Confirm",
      danger: opts.danger !== false,
      resolve: (value) => {
        setState(null);
        resolve(value);
      },
    });
  });
}

export function promptDialog(message, opts = {}) {
  return new Promise((resolve) => {
    setState({
      kind: "prompt",
      message,
      title: opts.title || "Please provide a reason",
      confirmLabel: opts.confirmLabel || "Submit",
      minLength: opts.minLength ?? 3,
      resolve: (value) => {
        setState(null);
        resolve(value);
      },
    });
  });
}

let toastListeners = new Set();
export function subscribeToast(fn) {
  toastListeners.add(fn);
  return () => toastListeners.delete(fn);
}

export function showToast(message, type = "info") {
  const toast = { id: Date.now() + Math.random(), message, type };
  toastListeners.forEach((fn) => fn(toast));
}
