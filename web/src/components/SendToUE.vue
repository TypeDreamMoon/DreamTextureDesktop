<script setup lang="ts">
// 「发送到 UE」：把当前这套材质推给一个正开着的虚幻编辑器。
//
// 在线的编辑器靠插件定时报到（后端 45 秒没心跳就当它下线），这里只负责问
// 后端"现在有谁在线"。三种情形：
//   没有   —— 按钮禁用，旁边直说原因。禁用而不是隐藏：隐藏的话用户会以为
//             这个功能不存在，而不是"编辑器没开"。
//   一个   —— 点了直接发。
//   多个   —— 点了弹出选择，选哪个发哪个。
import { computed, onBeforeUnmount, onMounted, ref } from 'vue'
import { NButton, NDropdown, useMessage } from 'naive-ui'
import { api } from '../api/client'
import type { UESession } from '../api/types'

const props = defineProps<{ materialId: string }>()
const message = useMessage()

const sessions = ref<UESession[]>([])
// 首次拉取之前不显示"没有在线的编辑器"——那会让每次进页面都先闪一下提示。
const loaded = ref(false)
const sending = ref(false)

async function refresh() {
  try {
    sessions.value = await api.ueSessions()
  } catch {
    // 后端暂时连不上就当没有；全局的断线提示会说明真正的原因，这里再弹一条是重复。
    sessions.value = []
  } finally {
    loaded.value = true
  }
}

// 页面开着的时候编辑器可能后来才启动（或中途关掉），定时再问一次，
// 不然按钮会一直停在拉取那一刻的状态，要刷新页面才能用。隐藏的标签页不问；
// 切回来时立刻问一次，不让人对着隐藏期间攒下的过期状态再等最多 10 秒。
let timer: ReturnType<typeof setInterval> | undefined
const onVisible = () => {
  if (document.visibilityState === 'visible') refresh()
}
onMounted(() => {
  refresh()
  timer = setInterval(onVisible, 10000)
  document.addEventListener('visibilitychange', onVisible)
})
onBeforeUnmount(() => {
  clearInterval(timer)
  document.removeEventListener('visibilitychange', onVisible)
})

async function send(sessionID?: string) {
  if (sending.value) return
  sending.value = true
  try {
    const r = await api.sendToUE(props.materialId, sessionID)
    message.success(`已发送到 ${r.session.name}，请到虚幻编辑器里查看导入结果`)
  } catch (e) {
    // 409（刚好下线、或又多了一个编辑器）这类都靠重拉一遍列表来纠正显示。
    message.error(String((e as Error).message))
    await refresh()
  } finally {
    sending.value = false
  }
}

const options = computed(() =>
  sessions.value.map((s) => ({
    key: s.session_id,
    label: s.engine ? `${s.name}（UE ${s.engine}）` : s.name,
  })),
)
</script>

<template>
  <span class="send-ue">
    <span v-if="loaded && sessions.length === 0" class="hint dt-faint">没有在线的虚幻编辑器</span>

    <NDropdown
      v-if="sessions.length > 1"
      trigger="click"
      :options="options"
      @select="(k: string) => send(k)"
    >
      <NButton size="small" :loading="sending">发送到 UE ▾</NButton>
    </NDropdown>
    <NButton
      v-else
      size="small"
      :disabled="sessions.length === 0"
      :loading="sending"
      @click="send()"
    >
      发送到 UE
    </NButton>
  </span>
</template>

<style scoped>
.send-ue {
  display: inline-flex;
  align-items: center;
  gap: 8px;
}
.hint {
  font-size: var(--dt-fs-xs);
}
</style>
