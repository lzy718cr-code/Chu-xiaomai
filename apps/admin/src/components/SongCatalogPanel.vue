<script setup>
import { ElAlert, ElButton, ElCard, ElDialog, ElEmpty, ElForm, ElFormItem, ElInput, ElInputNumber, ElMessage, ElMessageBox, ElSwitch, ElTable, ElTableColumn, ElTag } from "element-plus";
import "element-plus/es/components/alert/style/css";
import "element-plus/es/components/button/style/css";
import "element-plus/es/components/card/style/css";
import "element-plus/es/components/dialog/style/css";
import "element-plus/es/components/empty/style/css";
import "element-plus/es/components/form/style/css";
import "element-plus/es/components/form-item/style/css";
import "element-plus/es/components/input/style/css";
import "element-plus/es/components/input-number/style/css";
import "element-plus/es/components/switch/style/css";
import "element-plus/es/components/table/style/css";
import "element-plus/es/components/table-column/style/css";
import "element-plus/es/components/tag/style/css";
import "element-plus/es/components/message/style/css";
import "element-plus/es/components/message-box/style/css";
import { computed, onMounted, ref } from "vue";
import { useAdminStore } from "../stores/admin";
import * as api from "../services/api";

const store = useAdminStore();
const songs = ref([]), loading = ref(true), error = ref(""), saving = ref(false);
const keyword = ref(""), whitelistEnabled = ref(false), allowedIds = ref([]);
const editing = ref(null);
const filtered = computed(() => {
  const key = keyword.value.trim().toLowerCase();
  return songs.value.filter(song => !key || `${song.title} ${song.artist}`.toLowerCase().includes(key));
});

async function load() {
  loading.value = true; error.value = "";
  try {
    songs.value = await api.fetchSongCatalog();
    if (store.currentPeriod) {
      const policy = await api.fetchPeriodCatalogPolicy(store.currentPeriod.id);
      whitelistEnabled.value = policy.whitelist_enabled === true;
      allowedIds.value = policy.allowed_catalog_ids ?? [];
    }
  } catch (e) { error.value = e.message || "曲库读取失败"; }
  finally { loading.value = false; }
}

function openCreate() { editing.value = { id: "", title: "", artist: "", sourceUrl: "", durationSeconds: null, isAvailable: false, isActive: true, notes: "" }; }
function openEdit(song) { editing.value = { id: song.id, title: song.title, artist: song.artist, sourceUrl: song.source_url || "", durationSeconds: song.duration_seconds, isAvailable: song.is_available, isActive: song.is_active, notes: song.notes || "" }; }
async function saveSong() {
  if (!editing.value?.title.trim() || !editing.value?.artist.trim()) return ElMessage.warning("请填写歌曲名和歌手");
  saving.value = true;
  try { await api.upsertSongCatalog(editing.value); editing.value = null; await load(); ElMessage.success("曲库已保存"); }
  catch (e) { ElMessage.error(e.message || "保存失败"); }
  finally { saving.value = false; }
}
async function savePolicy() {
  if (!store.currentPeriod) return ElMessage.warning("请先创建征集期");
  if (whitelistEnabled.value && !allowedIds.value.length) {
    try { await ElMessageBox.confirm("当前白名单为空，开启后同学将无法选择任何歌曲。仍要开启吗？", "确认开启白名单", { type: "warning" }); } catch { return; }
  }
  saving.value = true;
  try { await api.savePeriodCatalogPolicy(store.currentPeriod.id, whitelistEnabled.value, allowedIds.value); ElMessage.success("本期选曲规则已保存"); }
  catch (e) { ElMessage.error(e.message || "规则保存失败"); }
  finally { saving.value = false; }
}
onMounted(load);
</script>

<template>
  <div>
    <el-card class="panel-card" shadow="never">
      <template #header><div class="panel-heading"><span>本期选曲范围</span><el-button :loading="saving" @click="savePolicy">保存规则</el-button></div></template>
      <el-alert title="曲库只展示广播台确认有音源的歌曲。开启白名单后，用户端只能从勾选的歌曲中投稿。规则按当前征集期生效。" type="info" :closable="false" show-icon />
      <div class="policy-row"><el-switch v-model="whitelistEnabled" active-text="开启本期白名单" inactive-text="使用全部可播歌曲" :disabled="loading || saving" /><span class="muted">开启前请先勾选允许投稿的歌曲</span></div>
      <el-button type="primary" :disabled="loading || saving" @click="savePolicy">保存当前征集期规则</el-button>
    </el-card>

    <el-card class="panel-card" shadow="never">
      <template #header><div class="panel-heading"><span>可播歌曲曲库（{{ filtered.length }} 首）</span><div><el-input v-model="keyword" placeholder="搜索歌曲或歌手" clearable style="width: 220px; margin-right: 10px" /><el-button type="primary" @click="openCreate">新增歌曲</el-button></div></div></template>
      <el-alert v-if="error" :title="error" type="error" :closable="false" show-icon />
      <el-table v-else-if="!loading" :data="filtered" stripe @selection-change="rows => allowedIds = rows.map(row => row.id)">
        <el-table-column v-if="whitelistEnabled" type="selection" width="50" :reserve-selection="true" :selectable="row => row.is_active && row.is_available" />
        <el-table-column prop="title" label="歌曲" min-width="180" />
        <el-table-column prop="artist" label="歌手" min-width="140" />
        <el-table-column label="音源状态" width="120"><template #default="{ row }"><el-tag :type="row.is_available && row.is_active ? 'success' : 'info'">{{ row.is_available && row.is_active ? '可投稿' : row.is_active ? '待补音源' : '已停用' }}</el-tag></template></el-table-column>
        <el-table-column label="时长" width="100"><template #default="{ row }">{{ row.duration_seconds ? `${Math.floor(row.duration_seconds / 60)}:${String(row.duration_seconds % 60).padStart(2, '0')}` : '-' }}</template></el-table-column>
        <el-table-column label="操作" width="100"><template #default="{ row }"><el-button size="small" @click="openEdit(row)">编辑</el-button></template></el-table-column>
        <template #empty><el-empty description="曲库暂无歌曲" :image-size="60" /></template>
      </el-table>
      <p v-else class="muted" role="status">正在读取曲库…</p>
    </el-card>

    <el-dialog :model-value="!!editing" :title="editing?.id ? '编辑曲库歌曲' : '新增曲库歌曲'" width="min(520px, 94vw)" :close-on-click-modal="false" @close="editing = null">
      <el-form v-if="editing" label-position="top" :disabled="saving">
        <el-form-item label="歌曲名" required><el-input v-model="editing.title" maxlength="80" /></el-form-item>
        <el-form-item label="歌手" required><el-input v-model="editing.artist" maxlength="80" /></el-form-item>
        <el-form-item label="音源地址或内部编号"><el-input v-model="editing.sourceUrl" maxlength="500" placeholder="用于工作人员核对，不直接暴露给用户" /></el-form-item>
        <el-form-item label="时长（秒）"><el-input-number v-model="editing.durationSeconds" :min="1" :max="3600" :controls="false" /></el-form-item>
        <el-form-item label="状态"><el-switch v-model="editing.isAvailable" active-text="确认有音源" /><el-switch v-model="editing.isActive" active-text="允许出现在曲库" style="margin-left: 20px" /></el-form-item>
        <el-form-item label="备注"><el-input v-model="editing.notes" type="textarea" maxlength="500" /></el-form-item>
      </el-form>
      <template #footer><el-button :disabled="saving" @click="editing = null">取消</el-button><el-button type="primary" :loading="saving" @click="saveSong">保存</el-button></template>
    </el-dialog>
  </div>
</template>

<style scoped>
.policy-row { display: flex; align-items: center; flex-wrap: wrap; gap: 16px; margin: 18px 0; }
.muted { color: var(--el-text-color-secondary); }
</style>
