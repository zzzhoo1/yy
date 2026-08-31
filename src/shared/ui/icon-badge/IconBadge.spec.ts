import { describe, it, expect } from 'vitest'
import { mount } from '@vue/test-utils'
import IconBadge from './IconBadge.vue'

describe('IconBadge', () => {
  it('renders the icon', () => {
    const wrapper = mount(IconBadge, {
      props: { icon: 'mdi-star' },
    })
    expect(wrapper.find('i').exists()).toBe(true)
  })

  it('renders the badge content when provided', () => {
    const wrapper = mount(IconBadge, {
      props: { icon: 'mdi-bell', content: 5 },
    })
    expect(wrapper.text()).toContain('5')
  })

  it('applies the passed color to the badge', () => {
    const wrapper = mount(IconBadge, {
      props: { icon: 'mdi-bell', color: 'red' },
    })
    expect(wrapper.find('span').attributes('class')).toContain('red')
  })
})
