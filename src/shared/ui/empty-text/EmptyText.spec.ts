import { describe, it, expect } from 'vitest'
import { mount } from '@vue/test-utils'
import EmptyText from './EmptyText.vue'

describe('EmptyText', () => {
  it('renders the empty text message', () => {
    const wrapper = mount(EmptyText)
    expect(wrapper.text()).toContain("Oops! It's still empty here.")
  })

  it('has the text-center class', () => {
    const wrapper = mount(EmptyText)
    expect(wrapper.classes()).toContain('text-center')
  })
})
