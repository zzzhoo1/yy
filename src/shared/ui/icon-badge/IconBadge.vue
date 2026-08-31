<template>
  <v-badge
    :content="content"
    :color="color"
    :dot="dot"
    :offset-x="offsetX"
    :offset-y="offsetY"
    :class="styles.badge"
  >
    <v-icon :icon="icon" :size="size" :color="iconColor" :class="styles.icon" />
  </v-badge>
</template>

<script setup lang="ts">
import styles from './styles.module.css'

withDefaults(
  defineProps<{
    icon: string
    content?: string | number
    color?: string
    iconColor?: string
    size?: string | number
    dot?: boolean
    offsetX?: string | number
    offsetY?: string | number
  }>(),
  {
    content: '',
    color: 'primary',
    iconColor: '',
    size: 'medium',
    dot: false,
    offsetX: 0,
    offsetY: 0,
  }
)
</script>
