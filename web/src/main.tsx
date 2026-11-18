import React from "react";
import ReactDOM from "react-dom/client";
import { BrowserRouter } from "react-router-dom";
import App from "./App";
import { AuthProvider } from "./auth";
import "sandcorp-design/css";
import "sandcorp-design/fonts.css";
import "./styles.css";
import mark from "sandcorp-design/assets/mark.svg";

document.querySelector<HTMLLinkElement>('link[rel="icon"]')?.setAttribute("href", mark);

ReactDOM.createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <BrowserRouter>
      <AuthProvider>
        <App />
      </AuthProvider>
    </BrowserRouter>
  </React.StrictMode>,
);
