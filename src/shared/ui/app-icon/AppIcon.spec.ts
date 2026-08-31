import { describe, it, expect } from 'vitest'
import { mount } from '@vue/test-utils'
import AppIcon from './AppIcon.vue'

describe('AppIcon', () => {
  it('renders the icon', () => {
    const wrapper = mount(AppIcon, {
      props: { icon: 'mdi-home' },
    })
    expect(wrapper.find('i').exists()).toBe(true)
  })

  it('applies the passed size', () => {
    const wrapper = mount(AppIcon, {
      props: { icon: 'mdi-home', size: 'large' },
    })
    expect(wrapper.find('i').classes()).toContain('v-icon--size-large')
  })
})
