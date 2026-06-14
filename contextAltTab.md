# Contexto del Proyecto:
Quiero desarrollar una aplicación nativa para macOS escrita en Swift y SwiftUI que replique la funcionalidad de "AltTab". 
La aplicación debe activarse globalmente al presionar la combinación de teclas Opción (Alt) + Tabulador [2, 3]. 
Al mantener presionada la tecla Opción y pulsar Tab, debe mostrar un panel flotante (HUD) en el centro de la pantalla con una lista horizontal de miniaturas visuales de todas las ventanas abiertas en el sistema [3]. Al soltar la tecla Opción, la aplicación debe traer al frente la ventana seleccionada [3].

## Requisitos Técnicos Críticos:
1. Captura de Miniaturas Reales (ScreenCaptureKit): Utiliza obligatoriamente el framework moderno ScreenCaptureKit de Apple para capturar imágenes en miniatura actualizadas de cada ventana (SCWindow) de forma eficiente y de alto rendimiento [1]. Implementa un filtro estricto para excluir ventanas invisibles, barras de menú, el Dock y fondos de pantalla.
2. Atajo Global (Opción + Tab): Utiliza APIs de bajo nivel como CGEvent.tapCreate o la API de accesibilidad para interceptar de forma global la combinación Opción + Tab, asegurando que el comportamiento nativo de macOS no bloquee la captura de la tecla Tab cuando Opción está presionada.
3. Interfaz de Usuario con SwiftUI: El panel de selección debe ser un NSPanel flotante sin bordes, con esquinas redondeadas, fondo difuminado nativo (efecto translúcido de macOS) y soporte para modo claro/oscuro. Debe mostrar la miniatura de la ventana, el ícono de la app propietaria en una esquina y el título del documento/ventana.

## Lógica de Navegación y Foco:
1. Mantener Opción presionado mantiene el HUD abierto [3].
2. Cada pulsación de Tab avanza al siguiente elemento de la lista.
3. Al soltar Opción, el HUD se oculta inmediatamente y se ejecuta la acción para traer al frente la ventana elegida usando AXUIElement de la API de Accesibilidad o activando la app con NSRunningApplication.Permisos de macOS: Incluye funciones para verificar y solicitar explícitamente al usuario los permisos de Grabación de Pantalla (necesario para ScreenCaptureKit) y Accesibilidad (necesario para controlar ventanas ajenas).