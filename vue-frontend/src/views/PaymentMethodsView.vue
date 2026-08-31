<script setup>
/* Purpose 5: list and update payment methods, including billing addresses. */
import { onMounted, reactive, ref } from 'vue'

import { api } from '../api'

const methods = ref([])
const error = ref(null)
const busy = ref(false)

// The method currently being edited, or null when the form is adding a new one.
const editingId = ref(null)

const blank = () => ({
  type: 'card',
  label: '',
  default: false,
  billingAddress: { line1: '', line2: null, city: '', region: '', postalCode: '', country: 'GB' },
})

const form = reactive(blank())

function reset() {
  editingId.value = null
  Object.assign(form, blank())
}

async function load() {
  error.value = null
  try {
    methods.value = (await api.paymentMethods()).methods
  } catch (err) {
    error.value = err.message
  }
}

onMounted(load)

function edit(method) {
  editingId.value = method.methodId
  Object.assign(form, {
    type: method.type,
    label: method.label,
    default: method.default,
    // Copy, do not alias. Binding the form straight to the row would edit the
    // rendered list live and leave it wrong if the request then failed.
    billingAddress: { ...method.billingAddress },
  })
}

async function submit() {
  busy.value = true
  error.value = null
  try {
    // PUT is a full replacement, which is why the form carries every field
    // rather than just the changed ones.
    if (editingId.value) await api.updatePaymentMethod(editingId.value, { ...form })
    else await api.addPaymentMethod({ ...form })
    reset()
    await load()
  } catch (err) {
    error.value = err.message
  } finally {
    busy.value = false
  }
}

async function remove(methodId) {
  busy.value = true
  try {
    await api.deletePaymentMethod(methodId)
    if (editingId.value === methodId) reset()
    await load()
  } catch (err) {
    error.value = err.message
  } finally {
    busy.value = false
  }
}
</script>

<template>
  <h1>Payment methods</h1>
  <p v-if="error" class="error">{{ error }}</p>

  <table v-if="methods.length">
    <thead>
      <tr><th>ID</th><th>Type</th><th>Label</th><th>Billing address</th><th>Default</th><th></th></tr>
    </thead>
    <tbody>
      <tr v-for="method in methods" :key="method.methodId">
        <td>{{ method.methodId }}</td>
        <td>{{ method.type }}</td>
        <td>{{ method.label }}</td>
        <td>{{ method.billingAddress.line1 }}, {{ method.billingAddress.postalCode }}</td>
        <td>{{ method.default ? 'yes' : '' }}</td>
        <td>
          <button type="button" :disabled="busy" @click="edit(method)">Edit</button>
          <button type="button" :disabled="busy" @click="remove(method.methodId)">Delete</button>
        </td>
      </tr>
    </tbody>
  </table>
  <p v-else>No payment methods.</p>

  <section class="card">
    <h2>{{ editingId ? `Edit ${editingId}` : 'Add a payment method' }}</h2>
    <form @submit.prevent="submit">
      <label>
        Type
        <select v-model="form.type">
          <option value="card">Card</option>
          <option value="direct_debit">Direct debit</option>
        </select>
      </label>
      <label>Label <input v-model="form.label" required /></label>

      <fieldset>
        <legend>Billing address</legend>
        <label>Line 1 <input v-model="form.billingAddress.line1" required /></label>
        <label>Line 2 <input v-model="form.billingAddress.line2" /></label>
        <label>City <input v-model="form.billingAddress.city" required /></label>
        <label>Region <input v-model="form.billingAddress.region" required /></label>
        <label>Postcode <input v-model="form.billingAddress.postalCode" required /></label>
        <label>Country <input v-model="form.billingAddress.country" required /></label>
      </fieldset>

      <label class="inline">
        <input v-model="form.default" type="checkbox" />
        Use as default
      </label>

      <button type="submit" :disabled="busy">{{ editingId ? 'Save' : 'Add' }}</button>
      <button v-if="editingId" type="button" @click="reset">Cancel</button>
    </form>
  </section>
</template>
