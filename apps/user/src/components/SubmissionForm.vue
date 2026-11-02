<script setup>
import { computed } from "vue";
import { useSongsStore } from "../stores/songs";
import { useDraftStore } from "../stores/draft";
import { usePeriodStatus } from "../composables/usePeriodStatus";
import { useRouter } from "vue-router";
import ConnectionNotice from "./ConnectionNotice.vue";

const songsStore = useSongsStore();
const { period, status: periodState } = usePeriodStatus();
const router = useRouter();
const draftStore = useDraftStore();
const draft = draftStore.draft;

const canMutate = computed(() => songsStore.canMutate);

async function handleSubmit() {
  const ok = await songsStore.submitSong(draft.catalogId);
  if (ok) draftStore.clear();
}

function selectCatalogSong(id) {
  const song = songsStore.catalogSongs.find((item) => item.id === id);
  draft.catalogId = id;
  draft.title = song?.title ?? "";
  draft.artist = song?.artist ?? "";
}

function viewSubmission() {
  const submission = songsStore.lastSubmission;
  if (!submission) return;
  router.push({ name: "playlist", query: {
    ...(submission.songId ? { song: submission.songId } : { songTitle: submission.title, songArtist: submission.artist }),
    period: submission.periodId,
  } });
}
</script>

<template>
  <section class="card form-panel" id="submit" :aria-busy="songsStore.isLoading || songsStore.isSubmitting">
    <div class="section-head">
      <div>
        <h2>今天，你想听什么？</h2>
      </div>
      <span class="no-login-note">{{ period?.isTest ? '测试账号已登录' : '无需登录' }}</span>
    </div>

    <div class="submission-period-card">
      <span class="period-state-chip" :class="periodState.className">{{ periodState.label }}</span>
      <div>
        <strong>{{ period?.title ?? "校园点歌征集" }}</strong>
        <p>{{ periodState.copy }}</p>
      </div>
    </div>

    <ConnectionNotice />
    <form class="song-form" @submit.prevent="handleSubmit">
      <label class="field song-picker">
        <span>选择可播歌曲</span>
        <select v-model="draft.catalogId" :disabled="songsStore.isSubmitting || songsStore.catalogLoading" required @change="selectCatalogSong(draft.catalogId)">
          <option value="">{{ songsStore.catalogLoading ? "正在读取可播歌曲…" : songsStore.catalogSongs.length ? "请选择歌曲" : "当前没有可播歌曲" }}</option>
          <option v-for="song in songsStore.catalogSongs" :key="song.id" :value="song.id">{{ song.title }} · {{ song.artist }}{{ song.durationSeconds ? ` · ${Math.floor(song.durationSeconds / 60)}:${String(song.durationSeconds % 60).padStart(2, '0')}` : '' }}</option>
        </select>
        <small v-if="draft.catalogId" class="field-help">已选择：{{ draft.title }} · {{ draft.artist }}。投稿只接受广播台已确认有音源的歌曲。</small>
      </label>
      <button class="primary-button" type="submit" :disabled="songsStore.isSubmitting || !canMutate">
        {{ songsStore.isSubmitting ? "正在投递…" : "提交这首歌 ↗" }}
      </button>
    </form>
    <p
      class="form-hint"
      :class="{ 'is-error': songsStore.formHintType === 'error', 'is-success': songsStore.formHintType === 'success' }"
      role="status"
    >
      {{ songsStore.formHint || songsStore.catalogError || (draftStore.hasDraft ? (draftStore.storageAvailable ? "草稿已暂存在当前标签页，切换页面或刷新后可继续填写。" : "浏览器未允许保存草稿，刷新或关闭页面后可能丢失。") : "请选择可播歌曲后提交；没有音源的歌曲不会进入投稿。") }}
    </p>
    <button v-if="draftStore.hasDraft" class="text-link" type="button" :disabled="songsStore.isSubmitting" @click="draftStore.clear()">清空草稿</button>
    <button v-if="songsStore.formHintType === 'success' && songsStore.lastSubmission" class="text-link" type="button" @click="viewSubmission">查看刚提交的歌曲 ↗</button>
    <router-link class="text-link participation-link" :to="{ name: 'home', hash: '#participationTitle' }">查看参与说明 ↓</router-link>
  </section>
</template>
