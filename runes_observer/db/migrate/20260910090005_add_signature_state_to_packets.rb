class AddSignatureStateToPackets < ActiveRecord::Migration[8.1]
  # doc5.md O0.3. `agent_id` used to be whatever the payload claimed; these two
  # columns say what backs the claim: the verdict on the envelope's Ed25519
  # signature (`unsigned`/`verified`/`untrusted`/`invalid`) and the signing
  # key's fingerprint. Indexed because "which packets came from this key" and
  # "did this agent ever publish under two keys" are the questions worth asking
  # of a shared broker.
  def change
    add_column :packets, :signature_state, :string
    add_column :packets, :key_fingerprint, :string
    add_index :packets, :key_fingerprint
  end
end
