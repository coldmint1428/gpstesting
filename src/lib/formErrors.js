// formErrors - form problems shown in the site's own style instead of the browser's bubble.
//
// A field marked `required` (or with a minlength, a pattern, type="email"...) makes the browser stop the submit and
// float its own grey "Please fill in this field." bubble, which looks like nothing else in the app. This listens for
// that once for the whole page: the bubble is cancelled, the field gets Bootstrap's red `is-invalid` border, and the
// message is written under it in the same red (controls.css, "Form errors"). The first field with a problem is focused.
// As soon as the field is fixed, the message goes away.
//
// Nothing here decides what is valid: that is still the field's own attributes, checked by the browser.

const ERROR_CLASS = 'field-error'

function isField(el) {
  return el instanceof HTMLInputElement || el instanceof HTMLSelectElement || el instanceof HTMLTextAreaElement
}

/** The sentence for a field's problem: short and in the app's voice, with the browser's own as the fallback. */
function messageFor(field) {
  const v = field.validity
  if (v.valueMissing) {
    if (field instanceof HTMLSelectElement) return 'Choose an option.'
    if (field.type === 'checkbox') return 'Tick this box to continue.'
    if (field.type === 'radio') return 'Choose one of these.'
    if (field.type === 'file') return 'Choose a file.'
    return 'Fill in this field.'
  }
  if (v.typeMismatch && field.type === 'email') return 'Enter an email address, like name@example.com.'
  if (v.typeMismatch && field.type === 'url') return 'Enter a web address, like https://example.com.'
  if (v.tooShort) return `Use at least ${field.minLength} characters (now ${field.value.length}).`
  if (v.tooLong) return `Use at most ${field.maxLength} characters.`
  if (v.rangeUnderflow) return `Enter ${field.min} or more.`
  if (v.rangeOverflow) return `Enter ${field.max} or less.`
  if (v.badInput && field.type === 'number') return 'Enter a number.'
  return field.validationMessage || 'Check this field.'
}

/** Where the message goes: under the whole input group or tick box, not between a field and its button. */
function anchorOf(field) {
  return field.closest('.input-group, .form-check, .form-switch') || field
}

function messageEl(field) {
  const anchor = anchorOf(field)
  const next = anchor.nextElementSibling
  return next && next.classList.contains(ERROR_CLASS) && next.dataset.for === fieldKey(field) ? next : null
}

let keys = 0
function fieldKey(field) {
  if (!field.dataset.errorKey) field.dataset.errorKey = String(++keys)
  return field.dataset.errorKey
}

function show(field) {
  field.classList.add('is-invalid')
  field.setAttribute('aria-invalid', 'true')
  let el = messageEl(field)
  if (!el) {
    el = document.createElement('div')
    el.className = ERROR_CLASS
    el.dataset.for = fieldKey(field)
    el.id = 'field-error-' + el.dataset.for
    el.setAttribute('role', 'alert')
    anchorOf(field).insertAdjacentElement('afterend', el)
  }
  el.textContent = messageFor(field)
  field.setAttribute('aria-describedby', el.id)
}

function clear(field) {
  if (!field.classList.contains('is-invalid') && !messageEl(field)) return
  field.classList.remove('is-invalid')
  field.removeAttribute('aria-invalid')
  const el = messageEl(field)
  if (el) {
    if (field.getAttribute('aria-describedby') === el.id) field.removeAttribute('aria-describedby')
    el.remove()
  }
}

let focusedThisRound = false

function onInvalid(event) {
  const field = event.target
  if (!isField(field)) return
  event.preventDefault() // no browser bubble
  show(field)
  // A submit raises one `invalid` per bad field, in order: the first one is where the cursor goes.
  if (!focusedThisRound) {
    focusedThisRound = true
    field.focus({ preventScroll: false })
    // A task, not a microtask: microtasks run between the `invalid` events of one submit, which would hand the
    // focus to every bad field in turn and leave it on the last.
    setTimeout(() => (focusedThisRound = false), 0)
  }
}

function onEdit(event) {
  const field = event.target
  if (!isField(field)) return
  // `validity.valid`, never checkValidity(): that would raise `invalid` again and show the message mid-typing.
  if (field.validity.valid) clear(field)
  else if (field.classList.contains('is-invalid')) show(field) // keep the sentence true while it is being fixed
  // Radio buttons share one answer: fixing one fixes the group.
  if (field.type === 'radio' && field.name && field.form) {
    for (const other of field.form.querySelectorAll(`input[type="radio"][name="${CSS.escape(field.name)}"]`)) {
      if (other.validity.valid) clear(other)
    }
  }
}

/** Install once, from main.js. */
export function installFormErrors() {
  if (typeof document === 'undefined' || document.documentElement.dataset.formErrors) return
  document.documentElement.dataset.formErrors = 'on'
  document.addEventListener('invalid', onInvalid, true)
  document.addEventListener('input', onEdit, true)
  document.addEventListener('change', onEdit, true)
  // A form that is reset starts clean.
  document.addEventListener(
    'reset',
    (event) => {
      const form = event.target
      if (!(form instanceof HTMLFormElement)) return
      for (const field of form.elements) if (isField(field)) clear(field)
    },
    true,
  )
}
