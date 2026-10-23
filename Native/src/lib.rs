use std::{ffi::{CStr,CString},os::raw::c_char,path::PathBuf,panic::{catch_unwind,AssertUnwindSafe}};
use sudachi::{config::Config,dic::dictionary::JapaneseDictionary,analysis::{stateful_tokenizer::StatefulTokenizer,Mode},prelude::MorphemeList};

pub struct Engine { dictionary: JapaneseDictionary }
#[no_mangle]
pub unsafe extern "C" fn ar_sudachi_create(directory:*const c_char) -> *mut Engine {
    if directory.is_null() { return std::ptr::null_mut(); }
    catch_unwind(AssertUnwindSafe(|| {
        let path=PathBuf::from(CStr::from_ptr(directory).to_str().ok()?);
        let cfg=Config::new(Some(path.join("sudachi.json")),Some(path.clone()),Some(path.join("system.dic"))).ok()?;
        Some(Box::into_raw(Box::new(Engine {dictionary:JapaneseDictionary::from_cfg(&cfg).ok()?})))
    })).ok().flatten().unwrap_or(std::ptr::null_mut())
}
#[no_mangle]
pub unsafe extern "C" fn ar_sudachi_tokenize(engine:*mut Engine,text:*const c_char) -> *mut c_char {
    let result=catch_unwind(AssertUnwindSafe(|| -> Result<serde_json::Value,String> {
        let engine=engine.as_ref().ok_or("Tokenizer not initialized")?;
        if text.is_null() { return Err("Missing text".into()); }
        let text=CStr::from_ptr(text).to_str().map_err(|e|e.to_string())?;
        let mut tokenizer=StatefulTokenizer::create(&engine.dictionary,false,Mode::B);
        tokenizer.reset().push_str(text);
        tokenizer.do_tokenize().map_err(|e|e.to_string())?;
        let mut morphemes=MorphemeList::empty(&engine.dictionary);
        morphemes.collect_results(&mut tokenizer).map_err(|e|e.to_string())?;
        let tokens:Vec<_>=morphemes.iter().map(|m|serde_json::json!({"surface":m.surface().to_string(),"lemma":m.dictionary_form(),"reading":m.reading_form(),"partOfSpeech":m.part_of_speech().join(","),"start":m.begin_c(),"end":m.end_c(),"unknown":m.is_oov()})).collect();
        Ok(serde_json::json!(tokens))
    }));
    let json=match result {Ok(Ok(v))=>v,Ok(Err(e))=>serde_json::json!({"error":e}),Err(_)=>serde_json::json!({"error":"Tokenizer failed"})};
    CString::new(json.to_string()).unwrap().into_raw()
}
#[no_mangle]
pub unsafe extern "C" fn ar_sudachi_free_string(text:*mut c_char) { if !text.is_null() {drop(CString::from_raw(text));} }
#[no_mangle]
pub unsafe extern "C" fn ar_sudachi_destroy(engine:*mut Engine) {if !engine.is_null() {drop(Box::from_raw(engine));}}
