// Prefs.swift
import Foundation
enum Prefs {
  static func set(_ v: Bool, for k: String) { UserDefaults.standard.set(v, forKey: k) }
  static func bool(for k: String) -> Bool { UserDefaults.standard.bool(forKey: k) }
  static func set(_ v: String?, for k: String) { UserDefaults.standard.set(v, forKey: k) }
  static func string(for k: String) -> String? { UserDefaults.standard.string(forKey: k) }

  static func setCustomUserId(_ id: String?) { set(id, for: "custom_user_id") }
  static func customUserId() -> String? { string(for: "custom_user_id") }
}