<script setup>
// ExpandTransition - the one way a section opens and closes: it unfolds downwards while fading in, and folds back up
// when it closes (timing in motion.css, "expand"). Wrap the v-if'd element:
//
//   <ExpandTransition><div v-if="open"><div class="pt-2">…</div></div></ExpandTransition>
//
// The height is measured here because CSS alone cannot animate to the height of content it has not laid out yet.
// Keep spacing (padding, margins) on an element inside the wrapped one: the wrapped element folds to nothing, and
// spacing on it would be left over and snap away at the end.
function toAuto(el) {
  el.style.height = ''
}
function onEnter(el) {
  el.style.height = '0px'
  void el.offsetHeight // apply the starting height before the target, or the browser skips the transition
  el.style.height = el.scrollHeight + 'px'
}
function onBeforeLeave(el) {
  el.style.height = el.scrollHeight + 'px'
  void el.offsetHeight
}
function onLeave(el) {
  el.style.height = '0px'
}
</script>

<template>
  <Transition name="expand" @enter="onEnter" @after-enter="toAuto" @enter-cancelled="toAuto" @before-leave="onBeforeLeave" @leave="onLeave" @after-leave="toAuto">
    <slot />
  </Transition>
</template>
