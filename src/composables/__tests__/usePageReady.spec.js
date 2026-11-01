// usePageReady: the page's skeleton stays until every panel's first load is in, then it is shown in one go.
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { defineComponent, h, ref, onMounted, nextTick } from 'vue'
import { mount } from '@vue/test-utils'
import { providePageReady, useLoadGate } from '../usePageReady'

// A panel that is loading from the start and answers after `ms`
const Panel = (ms) =>
  defineComponent({
    setup() {
      const loaded = ref(false)
      useLoadGate(() => !loaded.value)
      onMounted(() => setTimeout(() => (loaded.value = true), ms))
      return () => h('div')
    },
  })
// A panel whose loading flag starts false and turns on only as it mounts (the plan board's pattern)
const LateStarter = (ms) =>
  defineComponent({
    setup() {
      const loading = ref(false)
      useLoadGate(() => loading.value)
      onMounted(() => {
        loading.value = true
        setTimeout(() => (loading.value = false), ms)
      })
      return () => h('div')
    },
  })

function pageWith(children, options) {
  let page
  const Page = defineComponent({
    setup() {
      page = providePageReady(options)
      onMounted(() => nextTick(() => page.arm()))
      return () => h('div', children.map((c) => h(c)))
    },
  })
  mount(Page)
  return () => page.ready.value
}

describe('usePageReady', () => {
  beforeEach(() => vi.useFakeTimers())
  afterEach(() => vi.useRealTimers())

  it('waits for the slowest panel, then shows the page once', async () => {
    const ready = pageWith([Panel(100), LateStarter(400), Panel(250)])
    await vi.advanceTimersByTimeAsync(300)
    expect(ready()).toBe(false) // two have answered, the board has not
    await vi.advanceTimersByTimeAsync(150)
    expect(ready()).toBe(false) // all in, but still inside the short quiet wait
    await vi.advanceTimersByTimeAsync(100)
    expect(ready()).toBe(true)
  })

  it('waits for a load that only starts after another has answered', async () => {
    const loading = ref(true)
    const Chained = defineComponent({
      setup() {
        useLoadGate(() => loading.value)
        return () => h('div')
      },
    })
    const ready = pageWith([Chained])
    await vi.advanceTimersByTimeAsync(50)
    loading.value = false // first answer in...
    await vi.advanceTimersByTimeAsync(40)
    loading.value = true // ...and the next read starts inside the quiet wait
    await vi.advanceTimersByTimeAsync(500)
    expect(ready()).toBe(false)
    loading.value = false
    await vi.advanceTimersByTimeAsync(100)
    expect(ready()).toBe(true)
  })

  it('shows the page anyway when a panel never answers', async () => {
    const ready = pageWith([Panel(100), Panel(1e9)], { maxWaitMs: 2000 })
    await vi.advanceTimersByTimeAsync(1900)
    expect(ready()).toBe(false)
    await vi.advanceTimersByTimeAsync(200)
    expect(ready()).toBe(true)
  })

  it('does nothing on a page without a gate', () => {
    expect(() => mount(Panel(10))).not.toThrow()
  })
})
