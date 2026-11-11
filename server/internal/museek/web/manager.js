// Forms remain fully usable without JavaScript, including in mobile Safari.
document.querySelectorAll('form[data-upload]').forEach(form => {
  form.addEventListener('submit', event => {
    const files = Array.from(form.elements.files.files);
    const status = form.querySelector('[role=status]');
    if (files.length > 50 || files.some(file => file.size > 128 * 1024 * 1024) || files.reduce((size, file) => size + file.size, 0) > 511 * 1024 * 1024) {
      event.preventDefault();
      status.textContent = 'Choose up to 50 MP3s, 128 MB each, under 512 MB total.';
      return;
    }
    form.querySelector('button').disabled = true;
    status.textContent = 'Uploading… Keep this page open until the upload finishes.';
  });
});
document.querySelectorAll('form[data-library]').forEach(form => {
  form.addEventListener('submit', event => {
    if (!form.querySelector('input[name=tracks]:checked')) {
      event.preventDefault();
      const first = form.querySelector('input[name=tracks]');
      if (first) {
        first.setCustomValidity('Select at least one song.');
        first.reportValidity();
        form.addEventListener('change', () => first.setCustomValidity(''), { once: true });
      }
    }
  });
});
document.querySelectorAll('form[data-note] textarea').forEach(field => {
  field.addEventListener('input', () => {
    field.dataset.dirty = field.value !== field.defaultValue ? 'true' : 'false';
  });
  field.form.addEventListener('submit', () => { field.dataset.dirty = 'false'; });
});
window.addEventListener('beforeunload', event => {
  if (document.querySelector('textarea[data-dirty=true]')) { event.preventDefault(); event.returnValue = ''; }
});
